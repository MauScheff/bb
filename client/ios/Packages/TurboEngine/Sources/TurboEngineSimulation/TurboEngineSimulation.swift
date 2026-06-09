import Foundation
import TurboEngine

public struct EngineAppSnapshotProjection: Equatable, Sendable {
    public let isReady: Bool
    public let isJoined: Bool
    public let isTransmitting: Bool
    public let canTransmitNow: Bool
    public let statusMessage: String
}

public enum EngineAppSnapshotProjector {
    public static func derive(from snapshot: TurboEngineSnapshot) -> EngineAppSnapshotProjection {
        EngineAppSnapshotProjection(
            isReady: isReady(snapshot),
            isJoined: isJoined(snapshot.conversation),
            isTransmitting: isTransmitting(snapshot.transmit),
            canTransmitNow: canTransmit(snapshot.localTalkCapability),
            statusMessage: statusMessage(snapshot)
        )
    }

    private static func isReady(_ snapshot: TurboEngineSnapshot) -> Bool {
        guard case .joined(let conversation) = snapshot.conversation else { return false }
        guard case .ready = conversation.readiness else { return false }
        guard case .available = snapshot.localTalkCapability else { return false }
        return true
    }

    private static func isJoined(_ conversation: EngineConversationPhase) -> Bool {
        guard case .joined = conversation else { return false }
        return true
    }

    private static func isTransmitting(_ transmit: EngineTransmitPhase) -> Bool {
        guard case .active = transmit else { return false }
        return true
    }

    private static func canTransmit(_ capability: EngineCapability<TransmitCapabilityEvidence>) -> Bool {
        guard case .available = capability else { return false }
        return true
    }

    private static func statusMessage(_ snapshot: TurboEngineSnapshot) -> String {
        switch snapshot.transmit {
        case .active:
            return "Talking"
        case .beginning:
            return "Starting"
        case .stopping:
            return "Stopping"
        case .failed(let failure):
            return "Transmit failed: \(failure.reason)"
        case .idle:
            break
        }

        switch snapshot.receive {
        case .receiving:
            return "Receiving"
        case .awaitingPTTActivation:
            return "Waking audio"
        case .draining:
            return "Finishing audio"
        case .failed(let failure):
            return "Receive failed: \(failure.reason)"
        case .idle, .prepared:
            break
        }

        switch snapshot.conversation {
        case .joined:
            return "Ready"
        case .joining:
            return "Joining"
        case .requesting:
            return "Requesting"
        case .selected:
            return "Selected"
        case .incomingBeep:
            return "Incoming request"
        case .disconnecting:
            return "Disconnecting"
        case .recovering:
            return "Recovering"
        case .none:
            return "Idle"
        }
    }
}

public struct SyntheticMediaAdapter: Sendable {
    public init() {}

    public func chunks(
        transmitID: EngineTransmitID,
        from fromDeviceID: EngineDeviceID,
        to toDeviceID: EngineDeviceID,
        transport: EngineTransportPath,
        count: Int,
        mediaCapability: EngineMediaTransportCapability? = nil,
        receivedAtStartTick: UInt64? = nil,
        frameDurationTicks: UInt64 = 20
    ) -> [EngineAudioChunk] {
        (0 ..< count).map { index in
            EngineAudioChunk(
                id: EngineAudioChunkID("\(transmitID.rawValue)-chunk-\(String(format: "%04d", index))"),
                transmitID: transmitID,
                sequence: EngineAudioSequence(index),
                fromDeviceID: fromDeviceID,
                toDeviceID: toDeviceID,
                transport: transport,
                payloadDigest: EnginePayloadDigest("digest-\(transmitID.rawValue)-\(index)"),
                mediaCapability: mediaCapability,
                capturedAtTick: UInt64(index) * frameDurationTicks,
                receivedAtTick: receivedAtStartTick.map { $0 + UInt64(index) * frameDurationTicks },
                durationTicks: frameDurationTicks
            )
        }
    }
}

public enum VirtualNetworkFault: Equatable, Sendable {
    case drop(sequence: EngineAudioSequence)
    case duplicate(sequence: EngineAudioSequence)
    case reorder
}

public struct VirtualNetwork: Sendable {
    public var faults: [VirtualNetworkFault]

    public init(faults: [VirtualNetworkFault] = []) {
        self.faults = faults
    }

    public func deliver(_ chunks: [EngineAudioChunk]) -> [EngineAudioChunk] {
        var delivered: [EngineAudioChunk] = []
        for chunk in chunks {
            if faults.contains(.drop(sequence: chunk.sequence)) {
                continue
            }
            delivered.append(chunk)
            if faults.contains(.duplicate(sequence: chunk.sequence)) {
                delivered.append(chunk)
            }
        }
        if faults.contains(.reorder) {
            delivered.reverse()
        }
        return delivered
    }
}

public actor InMemoryEngineBackendPort: EngineBackendPort {
    private var seededHandles: Set<String> = []

    public init() {}

    public func seed(handle: String) async throws {
        seededHandles.insert(handle)
    }

    public func reset(handle: String) async throws {
        seededHandles.remove(handle)
    }

    public func connectWebSocket() async throws {}

    public func sendControlCommand(_ command: EngineControlCommand) async throws -> EngineControlResponse {
        switch command.kind {
        case .beginTransmit:
            return EngineControlResponse(
                status: .accepted,
                channelID: command.channelID,
                transmitID: EngineTransmitID("mem-\(command.channelID?.rawValue ?? "channel")-tx")
            )
        case .endTransmit:
            return EngineControlResponse(status: .accepted, channelID: command.channelID)
        }
    }

    public func fetchChannelState(_ channelID: EngineChannelID) async throws -> EngineChannelState {
        EngineChannelState(channelID: channelID, status: .ready)
    }
}

public enum LiveBackendPortError: Error, LocalizedError {
    case unavailable(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .unsupported(let message):
            return message
        }
    }
}

public final class LiveHTTPWebSocketEngineBackendPort: EngineBackendPort {
    private let baseURL: URL
    private let handle: String
    private let deviceID: EngineDeviceID
    private let peerHandle: String?
    private let peerDeviceID: EngineDeviceID?
    private let session: URLSession
    private var localUserID: String?
    private var peerUserID: String?
    private var liveChannelID: EngineChannelID?
    private var webSockets: [URLSessionWebSocketTask] = []

    public init(
        baseURL: URL,
        handle: String,
        deviceID: EngineDeviceID,
        peerHandle: String? = nil,
        peerDeviceID: EngineDeviceID? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.handle = handle
        self.deviceID = deviceID
        self.peerHandle = peerHandle
        self.peerDeviceID = peerDeviceID
        self.session = session
    }

    public func seed(handle: String) async throws {
        try await requestNoResponse(path: "/v1/dev/seed", method: "POST", handle: handle)
    }

    public func reset(handle: String) async throws {
        webSockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
        webSockets.removeAll()
        liveChannelID = nil
        try await requestNoResponse(path: "/v1/dev/reset-state", method: "POST", handle: handle)
    }

    public func connectWebSocket() async throws {
        _ = try await requestJSON(path: "/v1/config", method: "GET", handle: handle, body: Optional<EmptyBody>.none)
        try await prepareLiveLocalPairIfPossible()
    }

    public func sendControlCommand(_ command: EngineControlCommand) async throws -> EngineControlResponse {
        guard let requestedChannelID = command.channelID else {
            throw LiveBackendPortError.unsupported("control command \(command.kind.rawValue) requires a channel id")
        }
        let channelID = liveChannelID ?? requestedChannelID
        switch command.kind {
        case .beginTransmit:
            let response = try await requestJSON(
                path: "/v1/channels/\(channelID.rawValue)/begin-transmit",
                method: "POST",
                handle: handle,
                body: DeviceBody(deviceId: deviceID.rawValue)
            )
            return EngineControlResponse(
                status: engineControlStatus(response.string("status")),
                channelID: requestedChannelID,
                transmitID: response.string("transmitId").map { EngineTransmitID($0) }
            )
        case .endTransmit:
            _ = try await requestJSON(
                path: "/v1/channels/\(channelID.rawValue)/end-transmit",
                method: "POST",
                handle: handle,
                body: DeviceBody(deviceId: deviceID.rawValue)
            )
            return EngineControlResponse(status: .accepted, channelID: requestedChannelID)
        }
    }

    public func fetchChannelState(_ channelID: EngineChannelID) async throws -> EngineChannelState {
        let liveChannelID = liveChannelID ?? channelID
        let response = try await requestJSON(
            path: "/v1/channels/\(liveChannelID.rawValue)/state/\(deviceID.rawValue)",
            method: "GET",
            handle: handle,
            body: Optional<EmptyBody>.none
        )
        return EngineChannelState(
            channelID: channelID,
            status: engineChannelStatus(response.string("status") ?? response.string("conversationStatus"))
        )
    }

    private func prepareLiveLocalPairIfPossible() async throws {
        guard let peerHandle, let peerDeviceID else { return }
        guard liveChannelID == nil else { return }

        let localSession = try await requestJSON(
            path: "/v1/auth/session",
            method: "POST",
            handle: handle,
            body: Optional<EmptyBody>.none
        )
        let peerSession = try await requestJSON(
            path: "/v1/auth/session",
            method: "POST",
            handle: peerHandle,
            body: Optional<EmptyBody>.none
        )
        localUserID = localSession.string("userId")
        peerUserID = peerSession.string("userId")

        try await registerDevice(deviceID, handle: handle)
        try await registerDevice(peerDeviceID, handle: peerHandle)
        try await markPresenceOnline(deviceID, handle: handle)
        try await markPresenceOnline(peerDeviceID, handle: peerHandle)

        let direct = try await requestJSON(
            path: "/v1/channels/direct",
            method: "POST",
            handle: handle,
            body: OtherHandleBody(otherHandle: peerHandle)
        )
        guard let channelID = direct.string("channelId") else {
            throw LiveBackendPortError.unavailable("direct channel response did not include channelId")
        }
        liveChannelID = EngineChannelID(channelID)

        let peerSocket = try await openWebSocket(handle: peerHandle, deviceID: peerDeviceID)
        let localSocket = try await openWebSocket(handle: handle, deviceID: deviceID)
        webSockets = [peerSocket, localSocket]

        try await join(channelID: channelID, handle: handle, deviceID: deviceID)
        try await join(channelID: channelID, handle: peerHandle, deviceID: peerDeviceID)
        try await sendReceiverReadySignals(
            channelID: channelID,
            localSocket: localSocket,
            peerSocket: peerSocket
        )
        try await waitForPeerReceiverReady(channelID: channelID)
    }

    private func registerDevice(_ deviceID: EngineDeviceID, handle: String) async throws {
        _ = try await requestJSON(
            path: "/v1/devices/register",
            method: "POST",
            handle: handle,
            body: DeviceRegistrationBody(deviceId: deviceID.rawValue, deviceLabel: deviceID.rawValue)
        )
    }

    private func markPresenceOnline(_ deviceID: EngineDeviceID, handle: String) async throws {
        _ = try await requestJSON(
            path: "/v1/presence/foreground",
            method: "POST",
            handle: handle,
            body: DeviceBody(deviceId: deviceID.rawValue)
        )
    }

    private func join(channelID: String, handle: String, deviceID: EngineDeviceID) async throws {
        _ = try await requestJSON(
            path: "/v1/channels/\(channelID)/join",
            method: "POST",
            handle: handle,
            body: DeviceBody(deviceId: deviceID.rawValue)
        )
    }

    private func openWebSocket(handle: String, deviceID: EngineDeviceID) async throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(url: baseURL.appending(path: "/v1/ws"), resolvingAgainstBaseURL: false) else {
            throw LiveBackendPortError.unavailable("could not build websocket URL for \(deviceID.rawValue)")
        }
        let httpScheme = components.scheme
        components.scheme = httpScheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "deviceId", value: deviceID.rawValue)]
        guard let url = components.url else {
            throw LiveBackendPortError.unavailable("could not build websocket URL for \(deviceID.rawValue)")
        }
        var request = URLRequest(url: url)
        request.addValue(handle, forHTTPHeaderField: "x-turbo-user-handle")
        request.addValue("Bearer \(handle)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()
        let ack = try await task.receive()
        let payload: Data
        switch ack {
        case .data(let data):
            payload = data
        case .string(let text):
            payload = Data(text.utf8)
        @unknown default:
            throw LiveBackendPortError.unavailable("websocket returned an unknown acknowledgement")
        }
        let response = try JSONDecoder().decode(JSONObject.self, from: payload)
        guard response.string("status") == "connected",
              response.string("deviceId") == deviceID.rawValue else {
            throw LiveBackendPortError.unavailable("unexpected websocket acknowledgement: \(String(decoding: payload, as: UTF8.self))")
        }
        return task
    }

    private func sendReceiverReadySignals(
        channelID: String,
        localSocket: URLSessionWebSocketTask,
        peerSocket: URLSessionWebSocketTask
    ) async throws {
        guard let peerDeviceID else { return }
        guard let localUserID, let peerUserID else {
            throw LiveBackendPortError.unavailable("live-local user ids are not available for receiver-ready signaling")
        }
        try await sendLiveSignal(
            webSocket: peerSocket,
            type: "receiver-ready",
            channelID: channelID,
            fromUserID: peerUserID,
            fromDeviceID: peerDeviceID.rawValue,
            toUserID: localUserID,
            toDeviceID: deviceID.rawValue,
            payload: "receiver-ready"
        )
        try await sendLiveSignal(
            webSocket: localSocket,
            type: "receiver-ready",
            channelID: channelID,
            fromUserID: localUserID,
            fromDeviceID: deviceID.rawValue,
            toUserID: peerUserID,
            toDeviceID: peerDeviceID.rawValue,
            payload: "receiver-ready"
        )
    }

    private func waitForPeerReceiverReady(channelID: String) async throws {
        for _ in 0 ..< 20 {
            let readiness = try await requestJSON(
                path: "/v1/channels/\(channelID)/readiness/\(deviceID.rawValue)",
                method: "GET",
                handle: handle,
                body: Optional<EmptyBody>.none
            )
            if readiness.string(at: "audioReadiness", "peer", "kind") == "ready" {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LiveBackendPortError.unavailable("peer receiver-ready did not converge for live-local scenario")
    }

    private func sendLiveSignal(
        webSocket: URLSessionWebSocketTask,
        type: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        toUserID: String,
        toDeviceID: String,
        payload: String
    ) async throws {
        let message = LiveSignalEnvelope(
            type: type,
            channelId: channelID,
            fromUserId: fromUserID,
            fromDeviceId: fromDeviceID,
            toUserId: toUserID,
            toDeviceId: toDeviceID,
            payload: payload
        )
        let data = try JSONEncoder().encode(message)
        try await webSocket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func liveDeviceID(forSynthetic synthetic: EngineDeviceID, fallback: EngineDeviceID) -> EngineDeviceID {
        if synthetic == deviceID || synthetic == peerDeviceID {
            return synthetic
        }
        switch synthetic.rawValue {
        case "sender-device":
            return deviceID
        case "receiver-device":
            return peerDeviceID ?? fallback
        default:
            return fallback
        }
    }

    private func liveUserID(forDeviceID deviceID: EngineDeviceID) throws -> String {
        if deviceID == self.deviceID, let localUserID {
            return localUserID
        }
        if deviceID == peerDeviceID, let peerUserID {
            return peerUserID
        }
        throw LiveBackendPortError.unavailable("missing live user id for \(deviceID.rawValue)")
    }

    private func engineControlStatus(_ rawStatus: String?) -> EngineControlResponseStatus {
        guard let rawStatus else { return .accepted }
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "ok", "accepted", "connected", "ready", "success", "transmitting", "idle":
            return .accepted
        case "not-ready", "not_ready", "waiting", "waiting-for-peer", "waiting_for_peer":
            return .rejected(.notReady)
        case "unsupported":
            return .rejected(.unsupported)
        case "unavailable", "backend-unavailable", "backend_unavailable":
            return .rejected(.backendUnavailable)
        default:
            return .rejected(.unknown(rawStatus))
        }
    }

    private func engineChannelStatus(_ rawStatus: String?) -> EngineChannelStatus {
        guard let rawStatus else { return .unknown("missing") }
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "idle":
            return .idle
        case "waiting-for-peer", "waiting_for_peer", "waitingforpeer", "connecting":
            return .waitingForPeer
        case "ready", "connected":
            return .ready
        case "transmitting":
            return .transmitting
        case "receiving":
            return .receiving
        default:
            return .unknown(rawStatus)
        }
    }

    private func requestNoResponse(path: String, method: String, handle: String) async throws {
        _ = try await requestData(path: path, method: method, handle: handle, body: Optional<EmptyBody>.none)
    }

    private func requestJSON<Body: Encodable>(
        path: String,
        method: String,
        handle: String,
        body: Body
    ) async throws -> JSONObject {
        let data = try await requestData(path: path, method: method, handle: handle, body: body)
        return try JSONDecoder().decode(JSONObject.self, from: data)
    }

    private func requestData<Body: Encodable>(
        path: String,
        method: String,
        handle: String,
        body: Body
    ) async throws -> Data {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue(handle, forHTTPHeaderField: "x-turbo-user-handle")
        request.addValue("Bearer \(handle)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !(body is Optional<EmptyBody>) {
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LiveBackendPortError.unavailable("missing HTTP response from \(url.absoluteString)")
        }
        guard 200 ..< 300 ~= http.statusCode else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw LiveBackendPortError.unavailable(
                "\(method) \(path) failed with \(http.statusCode): \(responseBody)"
            )
        }
        return data.isEmpty ? Data("{}".utf8) : data
    }
}

public struct EngineEffectDriver: Sendable {
    public init() {}

    public func events(
        for effects: [TurboEngineEffect],
        backend: any EngineBackendPort
    ) async throws -> [TurboEngineEvent] {
        var events: [TurboEngineEvent] = []
        for effect in effects {
            switch effect {
            case .backend(.connectWebSocket):
                try await backend.connectWebSocket()

            case .backend(.beginTransmit(let channelID)):
                let response = try await backend.sendControlCommand(
                    EngineControlCommand(kind: .beginTransmit, channelID: channelID)
                )
                switch response.status {
                case .accepted:
                    guard let transmitID = response.transmitID else {
                        throw ScenarioError.backendRejected("begin transmit accepted without transmit id")
                    }
                    events.append(.backend(.beginTransmitAccepted(transmitID)))
                case .rejected(let reason):
                    throw ScenarioError.backendRejected("begin transmit rejected: \(reason)")
                }

            case .backend(.endTransmit(let channelID, let transmitID)):
                let response = try await backend.sendControlCommand(
                    EngineControlCommand(kind: .endTransmit, channelID: channelID)
                )
                switch response.status {
                case .accepted:
                    events.append(.backend(.stopTransmitAccepted(transmitID)))
                case .rejected(let reason):
                    throw ScenarioError.backendRejected("end transmit rejected: \(reason)")
                }

            case .backend(.fetchChannelState(let channelID)):
                _ = try await backend.fetchChannelState(channelID)

            case .ptt, .media, .transport, .diagnostics:
                continue
            }
        }
        return events
    }
}

private struct EmptyBody: Encodable {}

private struct DeviceBody: Encodable {
    let deviceId: String
}

private struct DeviceRegistrationBody: Encodable {
    let deviceId: String
    let deviceLabel: String
}

private struct OtherHandleBody: Encodable {
    let otherHandle: String
}

private struct LiveSignalEnvelope: Encodable {
    let type: String
    let channelId: String
    let fromUserId: String
    let fromDeviceId: String
    let toUserId: String
    let toDeviceId: String
    let payload: String
}

private struct JSONObject: Decodable {
    private let storage: [String: JSONValue]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        storage = try container.decode([String: JSONValue].self)
    }

    func string(_ key: String) -> String? {
        storage[key]?.string
    }

    func string(at path: String...) -> String? {
        guard let first = path.first else { return nil }
        var value = storage[first]
        for key in path.dropFirst() {
            guard case .object(let object) = value else { return nil }
            value = object[key]
        }
        return value?.string
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    var string: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .object, .array, .null:
            return nil
        }
    }
}

public struct EngineScenarioReport: Codable, Equatable, Sendable {
    public let name: String
    public let passed: Bool
    public let scheduledPlaybackCount: Int
    public let invariantIDs: [String]
    public let notes: [String]
}

public struct EngineScenarioRunner: Sendable {
    private let media = SyntheticMediaAdapter()

    public init() {}

    public func run(
        name: String,
        backend: (any EngineBackendPort)? = nil
    ) async throws -> EngineScenarioReport {
        let resolvedName = name.isEmpty ? "foreground_transmit_receive" : name
        if let fuzzCase = EngineFuzzCaseReference(name: resolvedName) {
            return try await composedFuzzCase(seed: fuzzCase.seed, index: fuzzCase.index, backend: backend)
        }

        switch resolvedName {
        case "foreground_transmit_receive":
            return try await foregroundTransmitReceive(backend: backend)
        case "locked_receiver_delayed_activation":
            return lockedReceiverDelayedActivation()
        case "background_audio_buffers_then_activation_drains":
            return backgroundAudioBuffersThenActivationDrains()
        case "active_transmit_network_migration":
            return activeTransmitNetworkMigration()
        case "direct_active_network_migration_fast_relay_reprobe":
            return directActiveNetworkMigrationFastRelayReprobe()
        case "fast_relay_quic_network_migration_preserves":
            return fastRelayQuicNetworkMigrationPreserves()
        case "fast_relay_quic_failure_tcp_then_no_media_route":
            return fastRelayQuicFailureTcpThenNoMediaRoute()
        case "wake_token_revocation_clears_active_transmit":
            return wakeTokenRevocationClearsActiveTransmit()
        case "active_transmit_membership_loss_clears_transmit":
            return activeTransmitMembershipLossClearsTransmit()
        case "idle_network_migration_then_transmit":
            return idleNetworkMigrationThenTransmit()
        case "stale_direct_generation_ignored":
            return staleDirectGenerationIgnored()
        case "quic_unavailable_fast_relay_fallback":
            return transportFallback(
                name: "quic_unavailable_fast_relay_fallback",
                failedPath: .directQuic,
                fallback: .fastRelay,
                reason: .quicBlocked
            )
        case "fast_relay_unavailable_no_media_route":
            return transportFallback(
                name: "fast_relay_unavailable_no_media_route",
                failedPath: .fastRelay,
                fallback: .relayWebSocket,
                reason: .relayUnavailable
            )
        case "direct_quic_send_failure_relay_fallback":
            return transportFallback(
                name: "direct_quic_send_failure_relay_fallback",
                failedPath: .directQuic,
                fallback: .fastRelay,
                reason: .peerUnavailable
            )
        case "duplicate_reordered_chunks":
            return duplicateReorderedChunks()
        case "direct_datagram_loss_reorder_duplicate":
            return packetMediaLossReorderDuplicate(
                name: "direct_datagram_loss_reorder_duplicate",
                transport: .directQuic
            )
        case "fast_relay_packet_loss_reorder_duplicate":
            return packetMediaLossReorderDuplicate(
                name: "fast_relay_packet_loss_reorder_duplicate",
                transport: .fastRelay
            )
        case "fast_relay_tcp_ordered_burst_drop":
            return orderedBurstDrop(
                name: "fast_relay_tcp_ordered_burst_drop",
                transport: .fastRelay,
                capability: .orderedReliableMedia(
                    OrderedReliableMediaEvidence(path: .fastRelay, reason: .fastRelayTcpFallback)
                ),
                expectedScheduledCount: 1,
                orderedBacklogDropped: true
            )
        case "stale_stop_behind_newer_start":
            return staleStopBehindNewerStart()
        case "incoming_audio_buffers_then_drains":
            return backgroundAudioBuffersThenActivationDrains()
        default:
            throw ScenarioError.unknownScenario(name)
        }
    }

    public func fuzz(
        seed: UInt64,
        count: Int,
        backend: (any EngineBackendPort)? = nil
    ) async throws -> [EngineScenarioReport] {
        var reports: [EngineScenarioReport] = []
        for index in 0 ..< count {
            reports.append(try await composedFuzzCase(seed: seed, index: index, backend: backend))
        }
        return reports
    }

    private func composedFuzzCase(
        seed: UInt64,
        index: Int,
        backend: (any EngineBackendPort)?
    ) async throws -> EngineScenarioReport {
        let config = EngineFuzzConfig(seed: seed, index: index)
        let scenarioBackend: any EngineBackendPort = backend ?? InMemoryEngineBackendPort()
        let effectDriver = EngineEffectDriver()
        var ledger = EngineFuzzLedger(expectedInvariantIDs: config.expectedInvariantIDs)
        var sender = TurboEngine(localDeviceID: "sender-device")
        var receiver = TurboEngine(localDeviceID: "receiver-device")

        try await scenarioBackend.seed(handle: "@avery")
        try await scenarioBackend.seed(handle: "@blake")
        try await scenarioBackend.connectWebSocket()

        ledger.collect(&sender, .event(.backend(.joined(joinedEvidence(transport: config.initialTransport)))))
        ledger.collect(&receiver, .event(.backend(.joined(joinedForReceiver(transport: config.initialTransport)))))

        if config.idleNetworkMigration {
            ledger.collect(&sender, .event(.transport(.networkChanged(config.networkInterface))))
            ledger.collect(&sender, .event(.transport(.fallbackSelected(config.idleMigrationFallback))))
        }

        if let failure = config.pathFailureBeforeTransmit {
            ledger.collect(&sender, .event(.transport(.pathFailed(failure.path, failure.reason))))
            ledger.collect(&sender, .event(.transport(.fallbackSelected(failure.fallback))))
        }

        let begin = ledger.collect(&sender, .intent(.beginTalk))
        let beginEvents = try await effectDriver.events(for: begin.effects, backend: scenarioBackend)
        guard let acceptedTransmitID = beginEvents.beginTransmitID else {
            throw ScenarioError.backendRejected("fuzz case \(config.reference.name) did not receive begin ack")
        }

        switch config.beginOrdering {
        case .backendFirst:
            ledger.apply(beginEvents, to: &sender)
            ledger.collect(&sender, .event(.ptt(.systemTransmitBegan(acceptedTransmitID))))
        case .systemFirst:
            ledger.collect(&sender, .event(.ptt(.systemTransmitBegan(acceptedTransmitID))))
            ledger.apply(beginEvents, to: &sender)
        case .backendThenSystemDuplicate:
            ledger.apply(beginEvents, to: &sender)
            ledger.collect(&sender, .event(.ptt(.systemTransmitBegan(acceptedTransmitID))))
            ledger.collect(&sender, .event(.ptt(.systemTransmitBegan(acceptedTransmitID))))
        }

        guard let transmitID = sender.snapshot.transmit.activeEpoch?.transmitID else {
            throw ScenarioError.backendRejected("fuzz case \(config.reference.name) did not enter active transmit")
        }

        if let failure = config.pathFailureDuringTransmit {
            ledger.collect(&sender, .event(.transport(.pathFailed(failure.path, failure.reason))))
            ledger.collect(&sender, .event(.transport(.fallbackSelected(failure.fallback))))
        }

        if config.activeNetworkMigration {
            ledger.collect(&sender, .event(.transport(.networkChanged(config.networkInterface))))
            ledger.collect(&sender, .event(.transport(.fallbackSelected(config.activeMigrationFallback))))
        }

        let prepare = remotePrepare(transmitID: transmitID)
        switch config.receiverLifecycle {
        case .foreground:
            break
        case .background:
            ledger.collect(&receiver, .event(.lifecycle(.moved(.background))))
        case .locked:
            ledger.collect(&receiver, .event(.lifecycle(.moved(.locked))))
        }

        ledger.collect(&receiver, .event(.backend(.remoteTransmitStarted(prepare))))

        if config.pushBeforeAudio {
            ledger.collect(&receiver, .event(.ptt(.incomingPush(prepare))))
        }

        if config.activationTiming == .beforeAudio {
            ledger.collect(
                &receiver,
                .event(.ptt(.audioActivated(PTTActivationEvidence(channelID: prepare.channelID, activatedAtTick: 100))))
            )
        }

        if config.injectStaleRemoteChunk {
            let stale = EngineAudioChunk(
                id: EngineAudioChunkID("stale-\(config.reference.name)-chunk"),
                transmitID: EngineTransmitID("stale-\(transmitID.rawValue)"),
                sequence: EngineAudioSequence(-1),
                fromDeviceID: "sender-device",
                toDeviceID: "receiver-device",
                transport: config.deliveryTransport,
                payloadDigest: EnginePayloadDigest("stale-digest-\(config.reference.name)")
            )
            ledger.collect(&receiver, .event(.media(.remoteAudioReceived(stale))))
        }

        let chunks = media.chunks(
            transmitID: transmitID,
            from: "sender-device",
            to: "receiver-device",
            transport: config.deliveryTransport,
            count: config.chunkCount
        )
        for chunk in chunks {
            let local = ledger.collect(&sender, .event(.media(.localAudioCaptured(chunk))))
            _ = try await effectDriver.events(for: local.effects, backend: scenarioBackend)
        }

        let deliveredChunks = VirtualNetwork(faults: config.networkFaults).deliver(chunks)
        let splitIndex = min(config.activationAfterChunkCount, deliveredChunks.count)
        let beforeActivation = deliveredChunks.prefix(splitIndex)
        let afterActivation = deliveredChunks.dropFirst(splitIndex)

        for chunk in beforeActivation {
            ledger.collect(&receiver, .event(.media(.remoteAudioReceived(chunk))))
        }

        if config.activationTiming == .deadlineThenActivate {
            ledger.collect(&receiver, .event(.clock(.deadlineElapsed(.pttActivation(prepare.channelID)))))
        }

        if config.activationTiming != .beforeAudio {
            ledger.collect(
                &receiver,
                .event(.ptt(.audioActivated(PTTActivationEvidence(channelID: prepare.channelID, activatedAtTick: 200))))
            )
        }

        for chunk in afterActivation {
            ledger.collect(&receiver, .event(.media(.remoteAudioReceived(chunk))))
        }

        let deliveredSequences = Set(deliveredChunks.map(\.sequence))
        for missingSequence in chunks.map(\.sequence) where !deliveredSequences.contains(missingSequence) {
            ledger.collect(
                &receiver,
                .event(.media(.playoutDeadlineElapsed(transmitID, missingSequence)))
            )
        }

        let end = ledger.collect(&sender, .intent(.endTalk))
        let endEvents = try await effectDriver.events(for: end.effects, backend: scenarioBackend)

        if config.injectStaleStopAck {
            ledger.collect(
                &sender,
                .event(.backend(.stopTransmitAccepted(EngineTransmitID("stale-\(transmitID.rawValue)"))))
            )
        }

        ledger.apply(endEvents, to: &sender)

        if config.duplicateStopAck {
            ledger.apply(endEvents, to: &sender)
        }

        ledger.collect(&receiver, .event(.backend(.remoteTransmitStopped(transmitID))))

        if config.injectLateChunkAfterStop {
            let late = EngineAudioChunk(
                id: EngineAudioChunkID("late-\(config.reference.name)-chunk"),
                transmitID: transmitID,
                sequence: EngineAudioSequence(config.chunkCount + 100),
                fromDeviceID: "sender-device",
                toDeviceID: "receiver-device",
                transport: config.deliveryTransport,
                payloadDigest: EnginePayloadDigest("late-digest-\(config.reference.name)")
            )
            ledger.collect(&receiver, .event(.media(.remoteAudioReceived(late))))
        }

        if config.drainPlayback {
            ledger.collect(&receiver, .event(.media(.playbackDrained(transmitID))))
        }

        ledger.inspectFinal(sender.snapshot)
        ledger.inspectFinal(receiver.snapshot)

        let scheduledPlaybackCount = receiver.snapshot.scheduledPlaybackCount
        let expectedPlaybackCount = Set(deliveredChunks.map(\.id)).count
        let playbackMatches = scheduledPlaybackCount == expectedPlaybackCount
        let notes = config.notes + [
            "replay=\(config.reference.name)",
            "expectedPlaybackCount=\(expectedPlaybackCount)",
            "scheduledPlaybackCount=\(scheduledPlaybackCount)",
            "unexpectedInvariantCount=\(ledger.unexpectedInvariantIDs.count)",
            "missingExpectedInvariantCount=\(ledger.missingExpectedInvariantIDs.count)",
        ]

        return EngineScenarioReport(
            name: config.reference.name,
            passed: playbackMatches && ledger.passed,
            scheduledPlaybackCount: scheduledPlaybackCount,
            invariantIDs: ledger.reportedInvariantIDs,
            notes: notes
        )
    }

    private func foregroundTransmitReceive(
        backend: (any EngineBackendPort)?
    ) async throws -> EngineScenarioReport {
        let scenarioBackend: any EngineBackendPort = backend ?? InMemoryEngineBackendPort()
        let effectDriver = EngineEffectDriver()
        try await scenarioBackend.seed(handle: "@avery")
        try await scenarioBackend.seed(handle: "@blake")
        try await scenarioBackend.connectWebSocket()
        var sender = TurboEngine(localDeviceID: "sender-device")
        var receiver = TurboEngine(localDeviceID: "receiver-device")
        let joined = joinedEvidence(transport: .fastRelay)
        collect(&sender, .event(.backend(.joined(joined))))
        collect(&receiver, .event(.backend(.joined(joinedForReceiver(transport: .fastRelay)))))
        let begin = collect(&sender, .intent(.beginTalk))
        apply(
            try await effectDriver.events(for: begin.effects, backend: scenarioBackend),
            to: &sender
        )
        collect(&sender, .event(.ptt(.systemTransmitBegan("tx-foreground"))))
        guard let transmitID = sender.snapshot.transmit.activeEpoch?.transmitID else {
            throw ScenarioError.backendRejected("begin transmit did not produce an active transmit epoch")
        }
        let chunks = media.chunks(
            transmitID: transmitID,
            from: "sender-device",
            to: "receiver-device",
            transport: .fastRelay,
            count: 10
        )
        collect(&receiver, .event(.backend(.remoteTransmitStarted(remotePrepare(transmitID: transmitID)))))
        for chunk in chunks {
            let localAudio = collect(&sender, .event(.media(.localAudioCaptured(chunk))))
            _ = try await effectDriver.events(for: localAudio.effects, backend: scenarioBackend)
            collect(&receiver, .event(.media(.remoteAudioReceived(chunk))))
        }
        let end = collect(&sender, .intent(.endTalk))
        apply(
            try await effectDriver.events(for: end.effects, backend: scenarioBackend),
            to: &sender
        )
        collect(&receiver, .event(.backend(.remoteTransmitStopped(transmitID))))
        return report(
            name: "foreground_transmit_receive",
            engines: [sender, receiver],
            notes: ["syntheticChunks=\(chunks.count)"]
        )
    }

    private func lockedReceiverDelayedActivation() -> EngineScenarioReport {
        var receiver = TurboEngine(localDeviceID: "receiver-device")
        collect(&receiver, .event(.backend(.joined(joinedForReceiver(transport: .fastRelay)))))
        collect(&receiver, .event(.lifecycle(.moved(.locked))))
        let prepare = remotePrepare(transmitID: "tx-locked")
        collect(&receiver, .event(.ptt(.incomingPush(prepare))))
        let chunks = media.chunks(
            transmitID: "tx-locked",
            from: "sender-device",
            to: "receiver-device",
            transport: .fastRelay,
            count: 4
        )
        for chunk in chunks {
            collect(&receiver, .event(.media(.remoteAudioReceived(chunk))))
        }
        let beforeActivation = receiver.snapshot.scheduledPlaybackCount
        collect(
            &receiver,
            .event(.ptt(.audioActivated(PTTActivationEvidence(channelID: "channel-a-b", activatedAtTick: 40))))
        )
        return report(
            name: "locked_receiver_delayed_activation",
            engines: [receiver],
            notes: [
                "scheduledBeforeActivation=\(beforeActivation)",
                "scheduledAfterActivation=\(receiver.snapshot.scheduledPlaybackCount)",
            ]
        )
    }

    private func backgroundAudioBuffersThenActivationDrains() -> EngineScenarioReport {
        var receiver = TurboEngine(localDeviceID: "receiver-device")
        var invariantIDs: [String] = []
        collect(&receiver, .event(.backend(.joined(joinedForReceiver(transport: .fastRelay)))))
        collect(&receiver, .event(.lifecycle(.moved(.background))))
        let prepare = remotePrepare(transmitID: "tx-background")
        collect(&receiver, .event(.backend(.remoteTransmitStarted(prepare))))
        let chunks = media.chunks(
            transmitID: "tx-background",
            from: "sender-device",
            to: "receiver-device",
            transport: .fastRelay,
            count: 4
        )
        for chunk in chunks {
            invariantIDs.append(contentsOf: collect(&receiver, .event(.media(.remoteAudioReceived(chunk)))).invariantViolations.map(\.invariantID))
        }
        let beforeActivation = receiver.snapshot.scheduledPlaybackCount
        invariantIDs.append(
            contentsOf: collect(
                &receiver,
                .event(.ptt(.audioActivated(PTTActivationEvidence(channelID: "channel-a-b", activatedAtTick: 40))))
            ).invariantViolations.map(\.invariantID)
        )
        let afterActivation = receiver.snapshot.scheduledPlaybackCount
        return EngineScenarioReport(
            name: "background_audio_buffers_then_activation_drains",
            passed: invariantIDs.isEmpty && beforeActivation == 0 && afterActivation == chunks.count,
            scheduledPlaybackCount: receiver.snapshot.scheduledPlaybackCount,
            invariantIDs: invariantIDs,
            notes: [
                "scheduledBeforeActivation=\(beforeActivation)",
                "scheduledAfterActivation=\(afterActivation)",
            ]
        )
    }

    private func activeTransmitNetworkMigration() -> EngineScenarioReport {
        var sender = activeSender(transmitID: "tx-migrate")
        collect(&sender, .event(.transport(.networkChanged(.cellular))))
        collect(
            &sender,
            .event(.transport(.pathAvailable(.fastRelay(FastRelayEvidence(host: "relay.beepbeep.to", port: 443)))))
        )
        return report(name: "active_transmit_network_migration", engines: [sender])
    }

    private func directActiveNetworkMigrationFastRelayReprobe() -> EngineScenarioReport {
        var sender = activeSender(
            transmitID: "tx-direct-migrate",
            joined: joinedEvidence(transport: .directQuic)
        )
        collect(
            &sender,
            .event(
                .transport(
                    .laneAvailable(
                        TransportLaneAvailability(lane: .fastRelayQuic, networkPathGeneration: 0)
                    )
                )
            )
        )
        collect(&sender, .event(.transport(.networkChanged(.cellular))))
        let snapshot = sender.snapshot
        let violations = EngineReducerSnapshot.inspect(snapshot).invariantIDs
        return EngineScenarioReport(
            name: "direct_active_network_migration_fast_relay_reprobe",
            passed: violations.isEmpty
                && snapshot.transportSelection.currentLane == .directQuic
                && snapshot.transportSelection.fallbackLane == .fastRelayQuic
                && snapshot.transportSelection.upgradeTarget == nil
                && snapshot.transport.currentPath == .directQuic,
            scheduledPlaybackCount: snapshot.scheduledPlaybackCount,
            invariantIDs: violations,
            notes: [
                "currentLane=\(snapshot.transportSelection.currentLane?.diagnosticsValue ?? "none")",
                "fallbackLane=\(snapshot.transportSelection.fallbackLane?.diagnosticsValue ?? "none")",
                "upgradeTarget=\(snapshot.transportSelection.upgradeTarget?.diagnosticsValue ?? "none")",
                "networkPathGeneration=\(snapshot.transportSelection.networkPathGeneration)",
            ]
        )
    }

    private func fastRelayQuicNetworkMigrationPreserves() -> EngineScenarioReport {
        var sender = activeSender(
            transmitID: "tx-fast-relay-migrate",
            joined: joinedEvidence(transport: .fastRelay)
        )
        collect(&sender, .event(.transport(.networkChanged(.cellular))))
        let snapshot = sender.snapshot
        let violations = EngineReducerSnapshot.inspect(snapshot).invariantIDs
        return EngineScenarioReport(
            name: "fast_relay_quic_network_migration_preserves",
            passed: violations.isEmpty
                && snapshot.transportSelection.currentLane == .fastRelayQuic
                && snapshot.transport.currentPath == .fastRelay,
            scheduledPlaybackCount: snapshot.scheduledPlaybackCount,
            invariantIDs: violations,
            notes: [
                "currentLane=\(snapshot.transportSelection.currentLane?.diagnosticsValue ?? "none")",
                "networkPathGeneration=\(snapshot.transportSelection.networkPathGeneration)",
            ]
        )
    }

    private func fastRelayQuicFailureTcpThenNoMediaRoute() -> EngineScenarioReport {
        var sender = TurboEngine(localDeviceID: "sender-device")
        collect(&sender, .event(.backend(.joined(joinedEvidence(transport: .fastRelay)))))
        collect(
            &sender,
            .event(
                .transport(
                    .laneAvailable(
                        TransportLaneAvailability(lane: .fastRelayTcp, networkPathGeneration: 0)
                    )
                )
            )
        )
        collect(
            &sender,
            .event(
                .transport(
                    .laneFailed(
                        TransportLaneFailure(
                            lane: .fastRelayQuic,
                            reason: .quicBlocked,
                            networkPathGeneration: 0
                        )
                    )
                )
            )
        )
        let afterQuicFailure = sender.snapshot.transportSelection.currentLane
        collect(
            &sender,
            .event(
                .transport(
                    .laneFailed(
                        TransportLaneFailure(
                            lane: .fastRelayTcp,
                            reason: .relayUnavailable,
                            networkPathGeneration: 0
                        )
                    )
                )
            )
        )
        let snapshot = sender.snapshot
        let violations = EngineReducerSnapshot.inspect(snapshot).invariantIDs
        return EngineScenarioReport(
            name: "fast_relay_quic_failure_tcp_then_no_media_route",
            passed: violations.isEmpty
                && afterQuicFailure == .fastRelayTcp
                && snapshot.transportSelection.currentLane == nil
                && snapshot.transport.currentPath == nil,
            scheduledPlaybackCount: snapshot.scheduledPlaybackCount,
            invariantIDs: violations,
            notes: [
                "afterQuicFailure=\(afterQuicFailure?.diagnosticsValue ?? "none")",
                "currentLane=\(snapshot.transportSelection.currentLane?.diagnosticsValue ?? "none")",
            ]
        )
    }

    private func idleNetworkMigrationThenTransmit() -> EngineScenarioReport {
        var sender = TurboEngine(localDeviceID: "sender-device")
        collect(&sender, .event(.backend(.joined(joinedEvidence(transport: .fastRelay)))))
        collect(&sender, .event(.transport(.networkChanged(.cellular))))
        collect(
            &sender,
            .event(.transport(.pathAvailable(.fastRelay(FastRelayEvidence(host: "relay.beepbeep.to", port: 443)))))
        )
        collect(&sender, .intent(.beginTalk))
        collect(&sender, .event(.backend(.beginTransmitAccepted("tx-after-idle-migration"))))
        collect(&sender, .event(.ptt(.systemTransmitBegan("system-after-idle-migration"))))
        return report(name: "idle_network_migration_then_transmit", engines: [sender])
    }

    private func staleDirectGenerationIgnored() -> EngineScenarioReport {
        var sender = TurboEngine(localDeviceID: "sender-device")
        collect(&sender, .event(.backend(.joined(joinedEvidence(transport: .directQuic)))))
        collect(
            &sender,
            .event(
                .transport(
                    .laneAvailable(
                        TransportLaneAvailability(lane: .fastRelayQuic, networkPathGeneration: 0)
                    )
                )
            )
        )
        collect(&sender, .event(.transport(.networkChanged(.cellular))))
        collect(
            &sender,
            .event(
                .transport(
                    .laneAvailable(
                        TransportLaneAvailability(lane: .directQuic, networkPathGeneration: 0)
                    )
                )
            )
        )
        let afterStale = sender.snapshot.transportSelection.currentLane
        collect(
            &sender,
            .event(
                .transport(
                    .laneAvailable(
                        TransportLaneAvailability(lane: .directQuic, networkPathGeneration: 1)
                    )
                )
            )
        )
        let snapshot = sender.snapshot
        let violations = EngineReducerSnapshot.inspect(snapshot).invariantIDs
        return EngineScenarioReport(
            name: "stale_direct_generation_ignored",
            passed: violations.isEmpty
                && afterStale == .fastRelayQuic
                && snapshot.transportSelection.currentLane == .directQuic,
            scheduledPlaybackCount: snapshot.scheduledPlaybackCount,
            invariantIDs: violations,
            notes: [
                "afterStale=\(afterStale?.diagnosticsValue ?? "none")",
                "currentLane=\(snapshot.transportSelection.currentLane?.diagnosticsValue ?? "none")",
                "networkPathGeneration=\(snapshot.transportSelection.networkPathGeneration)",
            ]
        )
    }

    private func wakeTokenRevocationClearsActiveTransmit() -> EngineScenarioReport {
        var sender = activeSender(
            transmitID: "tx-wake-revoked",
            joined: joinedEvidence(
                transport: .fastRelay,
                peerDevice: .pending(.waitingForPeerDevice),
                receiverAddressability: .wakeCapable(
                    WakeTargetEvidence(
                        channelID: "channel-a-b",
                        deviceID: "receiver-device",
                        tokenObservedAtTick: 1
                    )
                )
            )
        )
        let revoked = collect(
            &sender,
            .event(.backend(.receiverAddressabilityChanged(.unavailable(.wakeTokenRevoked))))
        )
        let stoppedForRevocation: Bool = {
            guard case .stopping(let stop) = revoked.state.transmit else { return false }
            return stop.reason == .receiverUnaddressable(.wakeTokenRevoked)
        }()
        let issuedBackendEnd = revoked.effects.contains(
            .backend(.endTransmit("channel-a-b", "tx-wake-revoked"))
        )
        let cleared = collect(
            &sender,
            .event(
                .backend(
                    .activeTransmitCleared(
                        "tx-wake-revoked",
                        .receiverBecameUnaddressable(.wakeTokenRevoked)
                    )
                )
            )
        )
        let invariantIDs = revoked.invariantViolations.map(\.invariantID)
            + cleared.invariantViolations.map(\.invariantID)
            + EngineReducerSnapshot.inspect(sender.snapshot).invariantIDs
        return EngineScenarioReport(
            name: "wake_token_revocation_clears_active_transmit",
            passed: invariantIDs.isEmpty
                && stoppedForRevocation
                && issuedBackendEnd
                && sender.snapshot.transmit == .idle,
            scheduledPlaybackCount: sender.snapshot.scheduledPlaybackCount,
            invariantIDs: invariantIDs,
            notes: [
                "stoppedForRevocation=\(stoppedForRevocation)",
                "issuedBackendEnd=\(issuedBackendEnd)",
            ]
        )
    }

    private func activeTransmitMembershipLossClearsTransmit() -> EngineScenarioReport {
        var sender = activeSender(transmitID: "tx-membership-lost")
        let lost = collect(
            &sender,
            .event(.backend(.receiverAddressabilityChanged(.unavailable(.membershipLost))))
        )
        let stoppedForMembershipLoss: Bool = {
            guard case .stopping(let stop) = lost.state.transmit else { return false }
            return stop.reason == .receiverUnaddressable(.membershipLost)
        }()
        let cleared = collect(
            &sender,
            .event(
                .backend(
                    .activeTransmitCleared(
                        "tx-membership-lost",
                        .receiverBecameUnaddressable(.membershipLost)
                    )
                )
            )
        )
        let invariantIDs = lost.invariantViolations.map(\.invariantID)
            + cleared.invariantViolations.map(\.invariantID)
            + EngineReducerSnapshot.inspect(sender.snapshot).invariantIDs
        return EngineScenarioReport(
            name: "active_transmit_membership_loss_clears_transmit",
            passed: invariantIDs.isEmpty
                && stoppedForMembershipLoss
                && sender.snapshot.transmit == .idle,
            scheduledPlaybackCount: sender.snapshot.scheduledPlaybackCount,
            invariantIDs: invariantIDs,
            notes: ["stoppedForMembershipLoss=\(stoppedForMembershipLoss)"]
        )
    }

    private func transportFallback(
        name: String,
        failedPath: EngineTransportPath,
        fallback: EngineTransportPath,
        reason: TransportUnavailableReason
    ) -> EngineScenarioReport {
        var engine = TurboEngine(localDeviceID: "sender-device")
        collect(&engine, .event(.backend(.joined(joinedEvidence(transport: failedPath)))))
        collect(&engine, .event(.transport(.pathFailed(failedPath, reason))))
        collect(&engine, .event(.transport(.fallbackSelected(fallback))))
        return report(name: name, engines: [engine])
    }

    private func duplicateReorderedChunks() -> EngineScenarioReport {
        var receiver = TurboEngine(localDeviceID: "receiver-device")
        collect(&receiver, .event(.backend(.joined(joinedForReceiver(transport: .fastRelay)))))
        collect(&receiver, .event(.backend(.remoteTransmitStarted(remotePrepare(transmitID: "tx-dup")))))
        let chunks = media.chunks(
            transmitID: "tx-dup",
            from: "sender-device",
            to: "receiver-device",
            transport: .fastRelay,
            count: 3
        )
        let network = VirtualNetwork(faults: [.duplicate(sequence: EngineAudioSequence(1)), .reorder])
        for chunk in network.deliver(chunks) {
            collect(&receiver, .event(.media(.remoteAudioReceived(chunk))))
        }
        return report(name: "duplicate_reordered_chunks", engines: [receiver])
    }

    private func packetMediaLossReorderDuplicate(
        name: String,
        transport: EngineTransportPath
    ) -> EngineScenarioReport {
        var receiver = TurboEngine(localDeviceID: "receiver-device")
        let transmitID = EngineTransmitID("\(name)-tx")
        collect(&receiver, .event(.backend(.joined(joinedForReceiver(transport: transport)))))
        collect(&receiver, .event(.backend(.remoteTransmitStarted(remotePrepare(transmitID: transmitID)))))
        let chunks = media.chunks(
            transmitID: transmitID,
            from: "sender-device",
            to: "receiver-device",
            transport: transport,
            count: 6,
            mediaCapability: .unorderedPacketMedia(
                UnorderedPacketMediaEvidence(
                    path: transport,
                    reason: transport == .directQuic ? .directQuicDatagram : .fastRelayPacketRelay
                )
            ),
            receivedAtStartTick: 0
        )
        let network = VirtualNetwork(
            faults: [
                .drop(sequence: EngineAudioSequence(2)),
                .duplicate(sequence: EngineAudioSequence(4)),
                .reorder,
            ]
        )
        let delivered = network.deliver(chunks)
        for chunk in delivered {
            collect(&receiver, .event(.media(.remoteAudioReceived(chunk))))
        }
        collect(&receiver, .event(.media(.playoutDeadlineElapsed(transmitID, EngineAudioSequence(2)))))
        let expectedScheduled = Set(delivered.map(\.sequence)).count
        return EngineScenarioReport(
            name: name,
            passed: receiver.snapshot.scheduledPlaybackCount == expectedScheduled
                && EngineReducerSnapshot.inspect(receiver.snapshot).invariantIDs.isEmpty,
            scheduledPlaybackCount: receiver.snapshot.scheduledPlaybackCount,
            invariantIDs: EngineReducerSnapshot.inspect(receiver.snapshot).invariantIDs,
            notes: [
                "transport=\(transport.rawValue)",
                "expectedScheduledPlaybackCount=\(expectedScheduled)",
            ]
        )
    }

    private func orderedBurstDrop(
        name: String,
        transport: EngineTransportPath,
        capability: EngineMediaTransportCapability,
        expectedScheduledCount: Int,
        orderedBacklogDropped: Bool
    ) -> EngineScenarioReport {
        var receiver = TurboEngine(localDeviceID: "receiver-device")
        let transmitID = EngineTransmitID("\(name)-tx")
        collect(&receiver, .event(.backend(.joined(joinedForReceiver(transport: transport)))))
        collect(&receiver, .event(.backend(.remoteTransmitStarted(remotePrepare(transmitID: transmitID)))))
        let chunks = media.chunks(
            transmitID: transmitID,
            from: "sender-device",
            to: "receiver-device",
            transport: transport,
            count: 8,
            mediaCapability: capability,
            receivedAtStartTick: 0
        )
        collect(&receiver, .event(.media(.remoteAudioReceived(chunks[0]))))
        for chunk in chunks.dropFirst().map({
            EngineAudioChunk(
                id: $0.id,
                transmitID: $0.transmitID,
                sequence: $0.sequence,
                fromDeviceID: $0.fromDeviceID,
                toDeviceID: $0.toDeviceID,
                transport: $0.transport,
                payloadDigest: $0.payloadDigest,
                mediaCapability: $0.mediaCapability,
                capturedAtTick: $0.capturedAtTick,
                receivedAtTick: 1_000,
                durationTicks: $0.durationTicks
            )
        }) {
            collect(&receiver, .event(.media(.remoteAudioReceived(chunk))))
        }
        let scheduled = receiver.snapshot.scheduledPlaybackCount
        return EngineScenarioReport(
            name: name,
            passed: scheduled == expectedScheduledCount && EngineReducerSnapshot.inspect(receiver.snapshot).invariantIDs.isEmpty,
            scheduledPlaybackCount: scheduled,
            invariantIDs: EngineReducerSnapshot.inspect(receiver.snapshot).invariantIDs,
            notes: [
                "orderedBacklogDropped=\(orderedBacklogDropped)",
                "transport=\(transport.rawValue)",
                "scheduledPlaybackCount=\(scheduled)",
            ]
        )
    }

    private func staleStopBehindNewerStart() -> EngineScenarioReport {
        var sender = TurboEngine(localDeviceID: "sender-device")
        collect(&sender, .event(.backend(.joined(joinedEvidence(transport: .fastRelay)))))
        collect(&sender, .intent(.beginTalk))
        collect(&sender, .event(.backend(.beginTransmitAccepted("tx-new"))))
        collect(&sender, .event(.ptt(.systemTransmitBegan("system-channel-a-b"))))
        collect(&sender, .intent(.endTalk))
        let stale = collect(&sender, .event(.backend(.stopTransmitAccepted("tx-old"))))
        return EngineScenarioReport(
            name: "stale_stop_behind_newer_start",
            passed: stale.invariantViolations.contains(where: {
                $0.invariantID == "transmit.stale_end_overrides_newer_epoch"
            }),
            scheduledPlaybackCount: sender.snapshot.scheduledPlaybackCount,
            invariantIDs: stale.invariantViolations.map(\.invariantID),
            notes: ["staleStopRejected=true"]
        )
    }

    private func activeSender(
        transmitID: EngineTransmitID,
        joined: JoinedConversationEvidence? = nil
    ) -> TurboEngine {
        var sender = TurboEngine(localDeviceID: "sender-device")
        collect(&sender, .event(.backend(.joined(joined ?? joinedEvidence(transport: .directQuic)))))
        collect(&sender, .intent(.beginTalk))
        collect(&sender, .event(.backend(.beginTransmitAccepted(transmitID))))
        collect(&sender, .event(.ptt(.systemTransmitBegan("system-channel-a-b"))))
        return sender
    }

    @discardableResult
    private func collect(_ engine: inout TurboEngine, _ input: ScenarioInput) -> TurboEngineTransition {
        switch input {
        case .intent(let intent):
            return engine.send(intent)
        case .event(let event):
            return engine.receive(event)
        }
    }

    private func apply(_ events: [TurboEngineEvent], to engine: inout TurboEngine) {
        for event in events {
            collect(&engine, .event(event))
        }
    }

    private func report(name: String, engines: [TurboEngine], notes: [String] = []) -> EngineScenarioReport {
        let violations = engines.flatMap { engine -> [String] in
            EngineReducerSnapshot.inspect(engine.snapshot).invariantIDs
        }
        let scheduledPlaybackCount = engines.reduce(0) { $0 + $1.snapshot.scheduledPlaybackCount }
        let expectedPlayback = name == "active_transmit_network_migration"
            || name == "idle_network_migration_then_transmit"
            || name.contains("fallback")
            ? true
            : scheduledPlaybackCount > 0
        return EngineScenarioReport(
            name: name,
            passed: violations.isEmpty && expectedPlayback,
            scheduledPlaybackCount: scheduledPlaybackCount,
            invariantIDs: violations,
            notes: notes
        )
    }

    private func joinedEvidence(
        transport: EngineTransportPath,
        peerDevice: EngineReadiness<PeerDeviceEvidence> = .ready(PeerDeviceEvidence(deviceID: "receiver-device")),
        receiverAddressability: ReceiverAddressability? = nil
    ) -> JoinedConversationEvidence {
        let membership = BackendMembershipEvidence(
            channelID: "channel-a-b",
            localDeviceID: "sender-device",
            peerDeviceID: "receiver-device",
            observedAtTick: 1
        )
        return JoinedConversationEvidence(
            friend: SelectedFriendEvidence(contactID: "blake", handle: "@blake"),
            channelID: "channel-a-b",
            localDeviceID: "sender-device",
            peerDevice: peerDevice,
            receiverAddressability: receiverAddressability,
            readiness: .ready(JoinedReadinessEvidence(backendMembershipObserved: membership, transport: transport))
        )
    }

    private func joinedForReceiver(transport: EngineTransportPath) -> JoinedConversationEvidence {
        let membership = BackendMembershipEvidence(
            channelID: "channel-a-b",
            localDeviceID: "receiver-device",
            peerDeviceID: "sender-device",
            observedAtTick: 1
        )
        return JoinedConversationEvidence(
            friend: SelectedFriendEvidence(contactID: "avery", handle: "@avery"),
            channelID: "channel-a-b",
            localDeviceID: "receiver-device",
            peerDevice: .ready(PeerDeviceEvidence(deviceID: "sender-device")),
            readiness: .ready(JoinedReadinessEvidence(backendMembershipObserved: membership, transport: transport))
        )
    }

    private func remotePrepare(transmitID: EngineTransmitID) -> RemoteTransmitPrepareEvidence {
        RemoteTransmitPrepareEvidence(
            channelID: "channel-a-b",
            transmitID: transmitID,
            senderDeviceID: "sender-device"
        )
    }
}

private enum ScenarioInput {
    case intent(TurboEngineIntent)
    case event(TurboEngineEvent)
}

private struct EngineFuzzCaseReference: Equatable, Sendable {
    let seed: UInt64
    let index: Int

    var name: String {
        "fuzz_case:\(seed):\(index)"
    }

    init(seed: UInt64, index: Int) {
        self.seed = seed
        self.index = index
    }

    init?(name: String) {
        let parts = name.split(separator: ":")
        guard parts.count == 3,
              parts[0] == "fuzz_case",
              let seed = UInt64(parts[1]),
              let index = Int(parts[2])
        else {
            return nil
        }
        self.seed = seed
        self.index = index
    }
}

private enum EngineFuzzBeginOrdering: String, Sendable {
    case backendFirst
    case systemFirst
    case backendThenSystemDuplicate
}

private enum EngineFuzzReceiverLifecycle: String, Sendable {
    case foreground
    case background
    case locked
}

private enum EngineFuzzActivationTiming: String, Sendable {
    case beforeAudio
    case afterSomeAudio
    case afterAllAudio
    case deadlineThenActivate
}

private struct EngineFuzzPathFailure: Sendable {
    let path: EngineTransportPath
    let reason: TransportUnavailableReason
    let fallback: EngineTransportPath

    var note: String {
        "\(path.rawValue)->\(fallback.rawValue)(\(reason))"
    }
}

private struct EngineFuzzConfig: Sendable {
    let reference: EngineFuzzCaseReference
    let initialTransport: EngineTransportPath
    let deliveryTransport: EngineTransportPath
    let beginOrdering: EngineFuzzBeginOrdering
    let receiverLifecycle: EngineFuzzReceiverLifecycle
    let activationTiming: EngineFuzzActivationTiming
    let pushBeforeAudio: Bool
    let activationAfterChunkCount: Int
    let chunkCount: Int
    let networkFaults: [VirtualNetworkFault]
    let idleNetworkMigration: Bool
    let activeNetworkMigration: Bool
    let networkInterface: EngineNetworkInterface
    let idleMigrationFallback: EngineTransportPath
    let activeMigrationFallback: EngineTransportPath
    let pathFailureBeforeTransmit: EngineFuzzPathFailure?
    let pathFailureDuringTransmit: EngineFuzzPathFailure?
    let injectStaleRemoteChunk: Bool
    let injectStaleStopAck: Bool
    let injectLateChunkAfterStop: Bool
    let duplicateStopAck: Bool
    let drainPlayback: Bool

    init(seed: UInt64, index: Int) {
        var rng = SeededGenerator(seed: seed ^ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15))
        reference = EngineFuzzCaseReference(seed: seed, index: index)

        initialTransport = rng.pick([.fastRelay, .directQuic])
        deliveryTransport = rng.pick([initialTransport, .fastRelay])
        beginOrdering = rng.pick([.backendFirst, .systemFirst, .backendThenSystemDuplicate])
        receiverLifecycle = rng.pick([.foreground, .background, .locked])

        var selectedActivationTiming: EngineFuzzActivationTiming = rng.pick([
            .beforeAudio,
            .afterSomeAudio,
            .afterAllAudio,
            .deadlineThenActivate,
        ])
        if receiverLifecycle == .foreground, selectedActivationTiming == .deadlineThenActivate {
            selectedActivationTiming = .afterSomeAudio
        }
        activationTiming = selectedActivationTiming
        pushBeforeAudio = activationTiming == .deadlineThenActivate || rng.nextBool()
        chunkCount = 3 + rng.nextInt(8)
        switch activationTiming {
        case .beforeAudio:
            activationAfterChunkCount = 0
        case .afterSomeAudio:
            activationAfterChunkCount = 1 + rng.nextInt(max(1, chunkCount - 1))
        case .afterAllAudio, .deadlineThenActivate:
            activationAfterChunkCount = chunkCount
        }

        var faults: [VirtualNetworkFault] = []
        if rng.oneIn(2) {
            faults.append(.duplicate(sequence: EngineAudioSequence(rng.nextInt(chunkCount))))
        }
        if rng.oneIn(3) {
            faults.append(.drop(sequence: EngineAudioSequence(rng.nextInt(chunkCount))))
        }
        if rng.oneIn(2) {
            faults.append(.reorder)
        }
        networkFaults = faults

        idleNetworkMigration = rng.oneIn(3)
        activeNetworkMigration = rng.oneIn(2)
        networkInterface = rng.pick([.wifi, .cellular])
        idleMigrationFallback = .fastRelay
        activeMigrationFallback = .fastRelay

        pathFailureBeforeTransmit = rng.oneIn(4)
            ? EngineFuzzConfig.makePathFailure(rng: &rng, initial: initialTransport)
            : nil
        pathFailureDuringTransmit = rng.oneIn(2)
            ? EngineFuzzConfig.makePathFailure(rng: &rng, initial: deliveryTransport)
            : nil

        injectStaleRemoteChunk = rng.oneIn(3)
        injectStaleStopAck = rng.oneIn(3)
        injectLateChunkAfterStop = rng.oneIn(3)
        duplicateStopAck = rng.oneIn(2)
        drainPlayback = rng.oneIn(2)
    }

    var expectedInvariantIDs: Set<String> {
        var ids: Set<String> = []
        if injectStaleRemoteChunk {
            ids.insert("engine.remote_audio_rejects_stale_epoch")
        }
        if injectStaleStopAck {
            ids.insert("transmit.stale_end_overrides_newer_epoch")
        }
        if injectLateChunkAfterStop {
            ids.insert("engine.no_playback_after_transmit_stop")
        }
        if activationTiming == .deadlineThenActivate {
            ids.insert("engine.ptt_activation_deadline_elapsed")
        }
        return ids
    }

    var notes: [String] {
        var result = [
            "initialTransport=\(initialTransport.rawValue)",
            "deliveryTransport=\(deliveryTransport.rawValue)",
            "beginOrdering=\(beginOrdering.rawValue)",
            "receiverLifecycle=\(receiverLifecycle.rawValue)",
            "activationTiming=\(activationTiming.rawValue)",
            "pushBeforeAudio=\(pushBeforeAudio)",
            "chunkCount=\(chunkCount)",
            "networkFaults=\(networkFaultNotes)",
            "idleNetworkMigration=\(idleNetworkMigration)",
            "activeNetworkMigration=\(activeNetworkMigration)",
            "networkInterface=\(networkInterface)",
            "injectStaleRemoteChunk=\(injectStaleRemoteChunk)",
            "injectStaleStopAck=\(injectStaleStopAck)",
            "injectLateChunkAfterStop=\(injectLateChunkAfterStop)",
            "duplicateStopAck=\(duplicateStopAck)",
            "drainPlayback=\(drainPlayback)",
        ]
        if let pathFailureBeforeTransmit {
            result.append("pathFailureBeforeTransmit=\(pathFailureBeforeTransmit.note)")
        }
        if let pathFailureDuringTransmit {
            result.append("pathFailureDuringTransmit=\(pathFailureDuringTransmit.note)")
        }
        return result
    }

    private var networkFaultNotes: String {
        if networkFaults.isEmpty {
            return "none"
        }
        return networkFaults.map { fault in
            switch fault {
            case .drop(let sequence):
                return "drop:\(sequence.rawValue)"
            case .duplicate(let sequence):
                return "duplicate:\(sequence.rawValue)"
            case .reorder:
                return "reorder"
            }
        }.joined(separator: ",")
    }

    private static func makePathFailure(
        rng: inout SeededGenerator,
        initial _: EngineTransportPath
    ) -> EngineFuzzPathFailure {
        EngineFuzzPathFailure(
            path: .directQuic,
            reason: rng.pick([.quicBlocked, .peerUnavailable, .noRoute]),
            fallback: .fastRelay
        )
    }
}

private struct EngineFuzzLedger {
    private let expectedInvariantIDs: Set<String>
    private var observedExpectedInvariantIDs: Set<String> = []
    private(set) var unexpectedInvariantIDs: [String] = []

    init(expectedInvariantIDs: Set<String>) {
        self.expectedInvariantIDs = expectedInvariantIDs
    }

    var missingExpectedInvariantIDs: [String] {
        expectedInvariantIDs.subtracting(observedExpectedInvariantIDs).sorted()
    }

    var reportedInvariantIDs: [String] {
        (Array(observedExpectedInvariantIDs) + unexpectedInvariantIDs).sorted()
    }

    var passed: Bool {
        unexpectedInvariantIDs.isEmpty && missingExpectedInvariantIDs.isEmpty
    }

    @discardableResult
    mutating func collect(_ engine: inout TurboEngine, _ input: ScenarioInput) -> TurboEngineTransition {
        let transition: TurboEngineTransition
        switch input {
        case .intent(let intent):
            transition = engine.send(intent)
        case .event(let event):
            transition = engine.receive(event)
        }
        record(transition.invariantViolations.map(\.invariantID))
        return transition
    }

    mutating func apply(_ events: [TurboEngineEvent], to engine: inout TurboEngine) {
        for event in events {
            collect(&engine, .event(event))
        }
    }

    mutating func inspectFinal(_ snapshot: TurboEngineSnapshot) {
        record(EngineReducerSnapshot.inspect(snapshot).invariantIDs)
    }

    private mutating func record(_ invariantIDs: [String]) {
        for invariantID in invariantIDs {
            if expectedInvariantIDs.contains(invariantID) {
                observedExpectedInvariantIDs.insert(invariantID)
            } else {
                unexpectedInvariantIDs.append(invariantID)
            }
        }
    }
}

private extension Array where Element == TurboEngineEvent {
    var beginTransmitID: EngineTransmitID? {
        for event in self {
            if case .backend(.beginTransmitAccepted(let transmitID)) = event {
                return transmitID
            }
        }
        return nil
    }
}

public enum ScenarioError: Error, LocalizedError {
    case unknownScenario(String)
    case backendRejected(String)

    public var errorDescription: String? {
        switch self {
        case .unknownScenario(let name):
            return "unknown engine scenario: \(name)"
        case .backendRejected(let message):
            return message
        }
    }
}

private struct EngineReducerSnapshot {
    let invariantIDs: [String]

    static func inspect(_ snapshot: TurboEngineSnapshot) -> EngineReducerSnapshot {
        var invariantIDs: [String] = []
        if case .active(let epoch) = snapshot.transmit,
           case .joined(let conversation) = snapshot.conversation,
           epoch.conversation.channelID != conversation.channelID {
            invariantIDs.append("engine.active_transmit_conversation_mismatch")
        }
        return EngineReducerSnapshot(invariantIDs: invariantIDs)
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x1234_5678 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        precondition(upperBound > 0, "upperBound must be positive")
        return Int(next() % UInt64(upperBound))
    }

    mutating func nextBool() -> Bool {
        next() & 1 == 0
    }

    mutating func oneIn(_ denominator: Int) -> Bool {
        nextInt(denominator) == 0
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[nextInt(values.count)]
    }
}
