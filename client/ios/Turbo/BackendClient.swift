import Foundation
import Network

struct TurboBackendCriticalHTTPClient: Sendable {
    let baseURL: URL
    let devUserHandle: String
    let deviceID: String
    let transportConfig: TurboBackendHTTPTransportConfig
    let session: URLSession

#if DEBUG
    nonisolated(unsafe) static var beginTransmitOverride:
        (@MainActor @Sendable (String, TurboBeginTransmitLeaseRequest) async throws -> TurboBeginTransmitResponse)?
#endif

    init(config: TurboBackendConfig) {
        baseURL = config.baseURL
        devUserHandle = config.devUserHandle
        deviceID = config.deviceID
        transportConfig = config.httpTransport
        session = URLSession(configuration: configuredSessionConfiguration(using: config.httpTransport))
    }

    func beginTransmit(
        channelId: String,
        request leaseRequest: TurboBeginTransmitLeaseRequest
    ) async throws -> TurboBeginTransmitResponse {
#if DEBUG
        if let beginTransmitOverride = Self.beginTransmitOverride {
            return try await beginTransmitOverride(channelId, leaseRequest)
        }
#endif
        let response: TurboBeginTransmitResponse = try await request(
            path: "/v1/channels/\(channelId)/begin-transmit",
            method: "POST",
            body: leaseRequest
        )
        return response
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue(devUserHandle, forHTTPHeaderField: "x-turbo-user-handle")
        request.addValue("Bearer \(devUserHandle)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TurboBackendError.invalidResponse
        }

        if 200 ..< 300 ~= http.statusCode {
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                throw TurboBackendError.invalidResponseDetails(
                    "\(method) \(path) decode failed: \(error.localizedDescription) body=\(body)"
                )
            }
        }

        if let error = try? JSONDecoder().decode(TurboErrorResponse.self, from: data) {
            throw TurboBackendError.server(error.error)
        }

        throw TurboBackendError.server(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }
}

private func configuredSessionConfiguration(
    using transportConfig: TurboBackendHTTPTransportConfig
) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.default
    configuration.waitsForConnectivity = transportConfig.waitsForConnectivity
    configuration.timeoutIntervalForRequest = transportConfig.requestTimeoutSeconds
    configuration.timeoutIntervalForResource = transportConfig.resourceTimeoutSeconds
    return configuration
}

@MainActor
final class TurboBackendClient: NSObject, URLSessionWebSocketDelegate {
    enum ControlCommandTransportTrace: String {
        case runtimeQuic = "runtime-quic-control"
        case runtimeTls = "runtime-tls-control"
        case webSocket = "websocket"
        case http
    }

    enum ControlCommandTracePhase: String {
        case started
        case sendCompleted = "send-completed"
        case hedgeStarted = "hedge-started"
        case responseReceived = "response-received"
        case failed
    }

    struct ControlCommandTraceEvent: Equatable {
        let commandKind: String
        let transport: ControlCommandTransportTrace
        let phase: ControlCommandTracePhase
        let operationId: String?
        let channelId: String?
        let requestId: String?
        let elapsedMs: Int?
        let detail: String?
    }

    enum WebSocketConnectionState: Equatable {
        case idle
        case connecting
        case connected
    }

    private let config: TurboBackendConfig
    private lazy var session: URLSession = {
        let configuration = configuredSessionConfiguration(using: config.httpTransport)
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private lazy var webSocketSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var webSocketPingTask: Task<Void, Never>?
    private var runtimeConfig: TurboBackendRuntimeConfig?
    private var webSocketConnectionState: WebSocketConnectionState = .idle
    private var currentWebSocketSessionID: String?
    private var shouldMaintainWebSocket = false
    private(set) var isWebSocketSuspended = false
    private let webSocketConnectTimeoutNanoseconds: UInt64 = 12_000_000_000
    private let webSocketControlCommandTimeoutNanoseconds: UInt64 = 3_000_000_000
    private var controlCommandHedgeDelayNanoseconds: UInt64 = 150_000_000
    private let webSocketPingIntervalNanoseconds: UInt64 = 20_000_000_000
    private var capturesSentSignalsForTesting = false
    private var capturedSentSignalsForTesting: [TurboSignalEnvelope] = []
#if DEBUG
    private var signalSendDelayNanosecondsForTesting: UInt64?
#endif
    private var capturesReceiverAudioReadinessForTesting = false
    private var capturedReceiverAudioReadinessForTesting: [TurboReceiverAudioReadinessRequest] = []
    private var pendingControlCommandResponses: [String: CheckedContinuation<Data, Error>] = [:]
    private var pendingControlCommandKinds: [String: String] = [:]
    private var webSocketPresenceCommandsRejected = false
    private let runtimeControlQueue = DispatchQueue(label: "TurboBackendClient.runtime-control")
    private var runtimeControlConnection: RuntimeControlConnection?
#if DEBUG
    var channelStateResponseForTesting: (@MainActor (String) async throws -> TurboChannelStateResponse)?
    var channelReadinessResponseForTesting: (@MainActor (String) async throws -> TurboChannelReadinessResponse)?
#endif
    var controlCommandHTTPResponseForTesting: (@MainActor (String, TurboControlCommandEnvelope) async throws -> Data)?
    var controlCommandWebSocketResponseForTesting: (@MainActor (TurboControlCommandEnvelope) async throws -> Data)?
    var controlCommandRuntimePersistentResponseForTesting:
        (@MainActor (TurboRuntimeControlLane, TurboControlCommandEnvelope) async throws -> Data)?

    var onSignal: (@MainActor (TurboSignalEnvelope) -> Void)?
    var onServerNotice: (@MainActor (String) -> Void)?
    var onWebSocketStatusNotice: (@MainActor (TurboWebSocketStatusNotice) -> Void)?
    var onWebSocketStateChange: (@MainActor (WebSocketConnectionState) -> Void)?
    var onControlCommandTrace: (@MainActor (ControlCommandTraceEvent) -> Void)?

    init(config: TurboBackendConfig) {
        self.config = config
    }

    var deviceID: String { config.deviceID }
    var devUserHandle: String { config.devUserHandle }
    var criticalHTTPClient: TurboBackendCriticalHTTPClient { TurboBackendCriticalHTTPClient(config: config) }
    var controlCommandTransportPolicy: TurboControlCommandTransportPolicy {
        TurboControlCommandTransportDebugOverride.policy() ?? config.controlCommandTransportPolicy
    }
    var supportsWebSocket: Bool { runtimeConfig?.supportsWebSocket ?? false }
    var canSendPresenceCommandsOverWebSocket: Bool {
        canAttemptWebSocketControlCommand && !webSocketPresenceCommandsRejected
    }
    var supportsDirectQuicUpgrade: Bool { runtimeConfig?.supportsDirectQuicUpgrade ?? false }
    var supportsMediaEndToEndEncryption: Bool { runtimeConfig?.supportsMediaEndToEndEncryption ?? false }
    var supportsSignalSessionIds: Bool { runtimeConfig?.supportsSignalSessionIds ?? false }
    var supportsTransmitIds: Bool { runtimeConfig?.supportsTransmitIds ?? false }
    var supportsProjectionEpochs: Bool { runtimeConfig?.supportsProjectionEpochs ?? false }
    var supportsRuntimeQuicControl: Bool { runtimeConfig?.supportsRuntimeQuicControl ?? false }
    var supportsRuntimeTlsControl: Bool { runtimeConfig?.supportsRuntimeTlsControl ?? false }
    var runtimeControlPreference: [TurboRuntimeControlLane] {
        runtimeConfig?.runtimeControl?.preference ?? [.runtimeHttpRequest]
    }
    var runtimeControlSelection: TurboRuntimeControlSelection {
        runtimeConfig?.runtimeControlSelection(requestedPolicy: controlCommandTransportPolicy)
            ?? TurboRuntimeControlSelection(
                requestedPolicy: controlCommandTransportPolicy,
                effectiveLane: .runtimeHttpRequest,
                fallbackReason: "runtime-config-unavailable"
            )
    }
    var directQuicPolicy: TurboDirectQuicPolicy? { runtimeConfig?.directQuicPolicy }
    var modeDescription: String { runtimeConfig?.mode ?? "unknown" }
    var isWebSocketConnected: Bool { webSocketConnectionState == .connected }
    var webSocketSessionID: String? { currentWebSocketSessionID }

    func fetchRuntimeConfig() async throws -> TurboBackendRuntimeConfig {
        let response: TurboBackendRuntimeConfig = try await request(path: "/v1/config")
        runtimeConfig = response
        invalidateRuntimeControlConnection()
        return response
    }

    func setRuntimeConfigForTesting(_ config: TurboBackendRuntimeConfig) {
        runtimeConfig = config
        invalidateRuntimeControlConnection()
    }

    func setControlCommandHedgeDelayForTesting(nanoseconds: UInt64) {
        controlCommandHedgeDelayNanoseconds = nanoseconds
    }

    func setWebSocketConnectedForControlCommandTesting(sessionID: String = "test-session") {
        currentWebSocketSessionID = sessionID
        setWebSocketConnectionState(.connected)
    }

    func rejectWebSocketPresenceCommandsForTesting() {
        webSocketPresenceCommandsRejected = true
    }

    func directQuicIceServers() async throws -> TurboDirectQuicIceServerPolicy {
        let path = runtimeConfig?.directQuicPolicy?.turnPolicyPath ?? "/v1/direct-quic/ice-servers"
        return try await request(path: path, method: "POST")
    }

    func authenticate() async throws -> TurboAuthSessionResponse {
        try await request(path: "/v1/auth/session", method: "POST")
    }

    func updateProfileName(_ profileName: String) async throws -> TurboAuthSessionResponse {
        try await request(
            path: "/v1/profile",
            method: "POST",
            body: TurboProfileUpdateRequest(profileName: profileName)
        )
    }

    func seedDevUsers() async throws -> TurboSeedResponse {
        try await request(path: "/v1/dev/seed", method: "POST")
    }

    func resetDevState() async throws -> TurboResetStateResponse {
        try await request(path: "/v1/dev/reset-state", method: "POST")
    }

    func resetAllDevState() async throws -> TurboResetStateResponse {
        try await request(path: "/v1/dev/reset-all", method: "POST")
    }

    func uploadDiagnostics(
        _ payload: TurboDiagnosticsUploadRequest,
        timeoutInterval: TimeInterval = 30
    ) async throws -> TurboDiagnosticsUploadResponse {
        try await request(
            path: "/v1/dev/diagnostics",
            method: "POST",
            body: payload,
            timeoutInterval: timeoutInterval
        )
    }

    func latestDiagnostics(deviceId: String) async throws -> TurboLatestDiagnosticsResponse {
        let escapedDeviceID = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceId
        return try await request(path: "/v1/dev/diagnostics/latest/\(escapedDeviceID)/")
    }

    func uploadTelemetry(_ payload: TurboTelemetryEventRequest) async throws -> TurboTelemetryUploadResponse {
        try await request(path: "/v1/telemetry/events", method: "POST", body: payload)
    }

    func registerDevice(
        label: String?,
        alertPushToken: String?,
        alertPushEnvironment: TurboAPNSEnvironment?,
        directQuicIdentity: DirectQuicIdentityRegistrationMetadata? = nil,
        mediaEncryptionIdentity: MediaEncryptionIdentityRegistrationMetadata? = nil
    ) async throws -> TurboDeviceRegistrationResponse {
        try await request(
            path: "/v1/devices/register",
            method: "POST",
            body: TurboRegisterDeviceRequest(
                deviceId: config.deviceID,
                deviceLabel: label,
                alertPushToken: alertPushToken,
                alertPushEnvironment: alertPushEnvironment?.rawValue,
                directQuicIdentity: directQuicIdentity,
                mediaEncryptionIdentity: mediaEncryptionIdentity
            )
        )
    }

    func lookupUser(handle: String) async throws -> TurboUserLookupResponse {
        try await request(path: "/v1/users/by-handle/\(handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle)")
    }

    func resolveIdentity(reference: String) async throws -> TurboUserLookupResponse {
        try await request(
            path: "/v1/identities/resolve",
            method: "POST",
            body: TurboResolveIdentityRequest(reference: reference)
        )
    }

    func rememberContact(
        otherHandle: String? = nil,
        otherUserId: String? = nil
    ) async throws -> TurboRememberContactResponse {
        try await request(
            path: "/v1/contacts/remember",
            method: "POST",
            body: TurboRememberContactRequest(otherHandle: otherHandle, otherUserId: otherUserId)
        )
    }

    func forgetContact(
        otherHandle: String? = nil,
        otherUserId: String? = nil
    ) async throws -> TurboForgetContactResponse {
        try await request(
            path: "/v1/contacts/forget",
            method: "POST",
            body: TurboForgetContactRequest(otherHandle: otherHandle, otherUserId: otherUserId)
        )
    }

    func lookupPresence(handle: String) async throws -> TurboUserPresenceResponse {
        try await request(path: Self.presenceLookupPath(for: handle))
    }

    func heartbeatPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await hedgedPresenceCommandRequest(
            path: "/v1/presence/keepalive",
            commandKind: "presence-keepalive",
            httpFallbackDelayNanoseconds: controlCommandHedgeDelayNanoseconds
        )
    }

    func foregroundPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await hedgedPresenceCommandRequest(
            path: "/v1/presence/foreground",
            commandKind: "presence-foreground",
            httpFallbackDelayNanoseconds: 0
        )
    }

    func offlinePresence() async throws -> TurboPresenceHeartbeatResponse {
        try await hedgedPresenceCommandRequest(
            path: "/v1/presence/offline",
            commandKind: "presence-offline",
            httpFallbackDelayNanoseconds: 0
        )
    }

    func backgroundPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await hedgedPresenceCommandRequest(
            path: "/v1/presence/background",
            commandKind: "presence-background",
            httpFallbackDelayNanoseconds: 0
        )
    }

    func contactSummaries() async throws -> [TurboContactSummaryResponse] {
        try await request(
            path: "/v1/contacts/summaries/\(config.deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.deviceID)"
        )
    }

    func directChannel(otherHandle: String? = nil, otherUserId: String? = nil) async throws -> TurboDirectChannelResponse {
        try await request(
            path: "/v1/channels/direct",
            method: "POST",
            body: TurboDirectChannelRequest(otherHandle: otherHandle, otherUserId: otherUserId)
        )
    }

    func joinChannel(
        channelId: String,
        operationId: String? = nil,
        deviceSessionProof: BackendJoinDeviceSessionProof? = nil
    ) async throws -> TurboJoinResponse {
        let envelope = TurboControlCommandEnvelope(
            commandKind: "join-channel",
            userHandle: config.devUserHandle,
            deviceId: config.deviceID,
            operationId: operationId,
            channelId: channelId,
            deviceSessionProof: deviceSessionProof?.rawValue
        )
        return try await hedgedControlCommandRequest(
            path: "/v1/channels/\(channelId)/join",
            body: envelope
        )
    }

    func leaveChannel(channelId: String, operationId: String? = nil) async throws -> TurboLeaveResponse {
        let envelope = TurboControlCommandEnvelope(
            commandKind: "leave-channel",
            userHandle: config.devUserHandle,
            deviceId: config.deviceID,
            operationId: operationId,
            channelId: channelId
        )
        return try await hedgedControlCommandRequest(
            path: "/v1/channels/\(channelId)/leave",
            body: envelope
        )
    }

    func channelState(channelId: String) async throws -> TurboChannelStateResponse {
#if DEBUG
        if let channelStateResponseForTesting {
            return try await channelStateResponseForTesting(channelId)
        }
#endif
        return try await request(
            path: "/v1/channels/\(channelId)/state/\(config.deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.deviceID)"
        )
    }

    func channelReadiness(channelId: String) async throws -> TurboChannelReadinessResponse {
#if DEBUG
        if let channelReadinessResponseForTesting {
            return try await channelReadinessResponseForTesting(channelId)
        }
#endif
        return try await request(
            path: "/v1/channels/\(channelId)/readiness/\(config.deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.deviceID)"
        )
    }

    func publishReceiverAudioReadiness(
        channelId: String,
        type: TurboSignalKind,
        payload: String
    ) async throws -> TurboReceiverAudioReadinessResponse {
        let body = TurboReceiverAudioReadinessRequest(
            deviceId: config.deviceID,
            type: type.rawValue,
            payload: payload
        )
        if capturesReceiverAudioReadinessForTesting {
            capturedReceiverAudioReadinessForTesting.append(body)
            return TurboReceiverAudioReadinessResponse(
                channelId: channelId,
                deviceId: config.deviceID,
                type: type.rawValue,
                audioReadiness: type == .receiverReady ? "ready" : "waiting",
                status: "stored"
            )
        }
        return try await request(
            path: "/v1/channels/\(channelId)/receiver-audio-readiness",
            method: "POST",
            body: body
        )
    }

    func createBeep(
        friendHandle: String? = nil,
        friendUserId: String? = nil,
        operationId: String? = nil,
        subject: String? = nil
    ) async throws -> TurboBeepResponse {
        let envelope = TurboControlCommandEnvelope(
            commandKind: "connect-request",
            userHandle: config.devUserHandle,
            deviceId: config.deviceID,
            operationId: operationId,
            friendHandle: friendHandle,
            friendUserId: friendUserId,
            subject: subject
        )
        return try await request(
            path: "/v1/beeps",
            method: "POST",
            body: envelope
        )
    }

    func incomingBeeps() async throws -> [TurboBeepResponse] {
        try await request(path: "/v1/beeps/incoming")
    }

    func outgoingBeeps() async throws -> [TurboBeepResponse] {
        try await request(path: "/v1/beeps/outgoing")
    }

    func acceptBeep(beepId: String) async throws -> TurboBeepResponse {
        try await request(path: "/v1/beeps/\(beepId)/accept", method: "POST")
    }

    func declineBeep(beepId: String) async throws -> TurboBeepResponse {
        try await request(path: "/v1/beeps/\(beepId)/decline", method: "POST")
    }

    func cancelBeep(beepId: String) async throws -> TurboBeepResponse {
        try await request(path: "/v1/beeps/\(beepId)/cancel", method: "POST")
    }

    func uploadEphemeralToken(
        channelId: String,
        token: String,
        apnsEnvironment: TurboAPNSEnvironment
    ) async throws -> TurboTokenResponse {
        try await request(
            path: "/v1/channels/\(channelId)/ephemeral-token",
            method: "POST",
            body: TurboEphemeralTokenRequest(
                deviceId: config.deviceID,
                token: token,
                apnsEnvironment: apnsEnvironment.rawValue
            )
        )
    }

    func revokeEphemeralToken(channelId: String) async throws -> TurboRevokeTokenResponse {
        try await request(
            path: "/v1/channels/\(channelId)/ephemeral-token/revoke",
            method: "POST",
            body: TurboDeviceOnlyRequest(deviceId: config.deviceID)
        )
    }

    func beginTransmit(
        channelId: String,
        request leaseRequest: TurboBeginTransmitLeaseRequest
    ) async throws -> TurboBeginTransmitResponse {
        try await request(
            path: "/v1/channels/\(channelId)/begin-transmit",
            method: "POST",
            body: leaseRequest
        )
    }

    func endTransmit(channelId: String, transmitId: String? = nil) async throws -> TurboEndTransmitResponse {
        try await request(
            path: "/v1/channels/\(channelId)/end-transmit",
            method: "POST",
            body: TurboChannelDeviceRequest(
                deviceId: config.deviceID,
                transmitId: supportsTransmitIds ? transmitId : nil
            )
        )
    }

    func renewTransmit(channelId: String, transmitId: String? = nil) async throws -> TurboRenewTransmitResponse {
        try await request(
            path: "/v1/channels/\(channelId)/renew-transmit",
            method: "POST",
            body: TurboChannelDeviceRequest(
                deviceId: config.deviceID,
                transmitId: supportsTransmitIds ? transmitId : nil
            )
        )
    }

    func connectWebSocket() {
        guard supportsWebSocket else { return }
        guard !isWebSocketSuspended else { return }
        shouldMaintainWebSocket = true
        reconnectTask?.cancel()
        reconnectTask = nil
        guard webSocketTask == nil else { return }
        guard webSocketConnectionState == .idle else { return }
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path =
            basePath.isEmpty
            ? "/v1/ws"
            : "/\(basePath)/v1/ws"
        components.queryItems = [URLQueryItem(name: "deviceId", value: config.deviceID)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.addValue(config.devUserHandle, forHTTPHeaderField: "x-turbo-user-handle")
        request.addValue("Bearer \(config.devUserHandle)", forHTTPHeaderField: "Authorization")
        let task = webSocketSession.webSocketTask(with: request)
        setWebSocketConnectionState(.connecting)
        currentWebSocketSessionID = nil
        webSocketTask = task
        scheduleConnectTimeout(for: task)
        task.resume()
    }

    func disconnectWebSocket() {
        shouldMaintainWebSocket = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        webSocketPingTask?.cancel()
        webSocketPingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        currentWebSocketSessionID = nil
        failPendingControlCommands(TurboBackendError.webSocketUnavailable)
        setWebSocketConnectionState(.idle)
    }

    func suspendWebSocket() {
        isWebSocketSuspended = true
        disconnectWebSocket()
    }

    func resumeWebSocket() {
        isWebSocketSuspended = false
        ensureWebSocketConnected()
    }

    func forceReconnectWebSocket() {
        guard supportsWebSocket else { return }
        isWebSocketSuspended = false
        disconnectWebSocket()
        connectWebSocket()
    }

    func ensureWebSocketConnected() {
        guard supportsWebSocket else { return }
        guard !isWebSocketSuspended else { return }
        if webSocketConnectionState == .connected {
            return
        }
        if webSocketConnectionState == .connecting {
            if webSocketTask == nil || webSocketTask?.state == .completed {
                connectTimeoutTask?.cancel()
                connectTimeoutTask = nil
                receiveTask?.cancel()
                receiveTask = nil
                webSocketPingTask?.cancel()
                webSocketPingTask = nil
                webSocketTask = nil
                currentWebSocketSessionID = nil
                failPendingControlCommands(TurboBackendError.webSocketUnavailable)
                setWebSocketConnectionState(.idle)
                onServerNotice?("WebSocket connecting task ended before open; reconnecting")
            } else {
                return
            }
        }
        connectWebSocket()
    }

    func waitForWebSocketConnection() async throws {
        guard supportsWebSocket else { return }
        ensureWebSocketConnected()
        for _ in 0 ..< 20 {
            if webSocketConnectionState == .connected {
                return
            }
            ensureWebSocketConnected()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TurboBackendError.webSocketUnavailable
    }

    func waitForWebSocketSessionIfNeeded() async throws {
        guard supportsWebSocket else { return }
        try await waitForWebSocketConnection()
        guard supportsSignalSessionIds else { return }
        for _ in 0 ..< 20 {
            if currentWebSocketSessionID != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TurboBackendError.webSocketUnavailable
    }

    func sendSignal(_ envelope: TurboSignalEnvelope) async throws {
        guard supportsWebSocket else {
            throw TurboBackendError.webSocketUnavailable
        }
        let stampedEnvelope: TurboSignalEnvelope
        if supportsSignalSessionIds {
            if currentWebSocketSessionID == nil {
                try await waitForWebSocketSessionIfNeeded()
            }
            stampedEnvelope = envelope.withSessionId(currentWebSocketSessionID)
        } else {
            stampedEnvelope = envelope
        }
#if DEBUG
        if let signalSendDelayNanosecondsForTesting {
            try? await Task.sleep(nanoseconds: signalSendDelayNanosecondsForTesting)
        }
#endif
        if capturesSentSignalsForTesting {
            capturedSentSignalsForTesting.append(stampedEnvelope)
            return
        }
        if webSocketConnectionState != .connected || webSocketTask == nil {
            try await waitForWebSocketSessionIfNeeded()
        }
        guard webSocketConnectionState == .connected, let webSocketTask else {
            throw TurboBackendError.webSocketUnavailable
        }
        let data = try JSONEncoder().encode(stampedEnvelope)
        let text = String(decoding: data, as: UTF8.self)
        try await webSocketTask.send(.string(text))
    }

    func setWebSocketConnectionStateForTesting(_ state: WebSocketConnectionState) {
        webSocketConnectionState = state
    }

    func setWebSocketSessionIDForTesting(_ sessionID: String?) {
        currentWebSocketSessionID = sessionID
    }

    func enableSentSignalCaptureForTesting() {
        capturesSentSignalsForTesting = true
        capturedSentSignalsForTesting = []
    }

#if DEBUG
    func setSignalSendDelayForTesting(nanoseconds: UInt64?) {
        signalSendDelayNanosecondsForTesting = nanoseconds
    }
#endif

    func sentSignalsForTesting() -> [TurboSignalEnvelope] {
        capturedSentSignalsForTesting
    }

    func enableReceiverAudioReadinessCaptureForTesting() {
        capturesReceiverAudioReadinessForTesting = true
        capturedReceiverAudioReadinessForTesting = []
    }

    func receiverAudioReadinessPublishesForTesting() -> [TurboReceiverAudioReadinessRequest] {
        capturedReceiverAudioReadinessForTesting
    }

    private func listenForMessages() async {
        guard let webSocketTask else { return }

        do {
            while !Task.isCancelled {
                let message = try await webSocketTask.receive()
                switch message {
                case let .string(text):
                    if let data = text.data(using: .utf8),
                       handleWebSocketCommandResponseData(data) {
                        continue
                    } else if let data = text.data(using: .utf8),
                              let envelope = try? JSONDecoder().decode(TurboSignalEnvelope.self, from: data) {
                        onSignal?(envelope)
                    } else if let data = text.data(using: .utf8),
                              let notice = try? JSONDecoder().decode(TurboWebSocketStatusNotice.self, from: data) {
                        if notice.status == "connected" {
                            currentWebSocketSessionID = notice.sessionId
                        }
                        onWebSocketStatusNotice?(notice)
                    } else if let data = text.data(using: .utf8),
                              let error = try? JSONDecoder().decode(TurboErrorResponse.self, from: data) {
                        handleWebSocketErrorNotice(error.error)
                        onServerNotice?(error.error)
                    } else {
                        onServerNotice?(text)
                    }
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        onServerNotice?(text)
                    }
                @unknown default:
                    onServerNotice?("Received unknown websocket message")
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.receiveTask = nil
            self.webSocketTask = nil
            self.currentWebSocketSessionID = nil
            self.webSocketPingTask?.cancel()
            self.webSocketPingTask = nil
            self.failPendingControlCommands(TurboBackendError.webSocketUnavailable)
            self.setWebSocketConnectionState(.idle)
            let reason = "WebSocket disconnected: \(error.localizedDescription)"
            onServerNotice?(reason)
            scheduleReconnect(reason: reason)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.webSocketTask === webSocketTask else { return }
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.webSocketPresenceCommandsRejected = false
            self.setWebSocketConnectionState(.connected)
            self.onServerNotice?("WebSocket connected")
            self.receiveTask?.cancel()
            self.receiveTask = Task { [weak self] in
                await self?.listenForMessages()
            }
            self.startWebSocketPingLoop(for: webSocketTask)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.webSocketTask === webSocketTask else { return }
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.webSocketPingTask?.cancel()
            self.webSocketPingTask = nil
            self.webSocketTask = nil
            self.currentWebSocketSessionID = nil
            self.failPendingControlCommands(TurboBackendError.webSocketUnavailable)
            self.setWebSocketConnectionState(.idle)
            if self.shouldMaintainWebSocket {
                let reason =
                    closeCode == .normalClosure
                    ? "WebSocket disconnected: closed normally"
                    : "WebSocket disconnected: closed with code \(closeCode.rawValue)"
                self.onServerNotice?(reason)
                self.scheduleReconnect(reason: reason)
            } else if closeCode != .normalClosure {
                let reason = "WebSocket disconnected: closed with code \(closeCode.rawValue)"
                self.onServerNotice?(reason)
                self.scheduleReconnect(reason: reason)
            }
        }
    }

    private func setWebSocketConnectionState(_ state: WebSocketConnectionState) {
        guard webSocketConnectionState != state else { return }
        webSocketConnectionState = state
        onWebSocketStateChange?(state)
    }

    private func scheduleReconnect(reason: String) {
        guard supportsWebSocket, shouldMaintainWebSocket else { return }
        guard reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            guard self.shouldMaintainWebSocket else { return }
            self.reconnectTask = nil
            self.onServerNotice?("\(reason). Reconnecting…")
            self.connectWebSocket()
        }
    }

    private func startWebSocketPingLoop(for task: URLSessionWebSocketTask) {
        webSocketPingTask?.cancel()
        webSocketPingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.webSocketPingIntervalNanoseconds ?? 20_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.webSocketTask === task,
                      self.webSocketConnectionState == .connected else {
                    return
                }
                task.sendPing { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.webSocketTask === task else { return }
                        let reason = "WebSocket ping failed: \(error.localizedDescription)"
                        self.onServerNotice?(reason)
                        self.webSocketPingTask?.cancel()
                        self.webSocketPingTask = nil
                        self.receiveTask?.cancel()
                        self.receiveTask = nil
                        self.webSocketTask = nil
                        self.currentWebSocketSessionID = nil
                        self.failPendingControlCommands(TurboBackendError.webSocketUnavailable)
                        self.setWebSocketConnectionState(.idle)
                        task.cancel(with: .goingAway, reason: nil)
                        self.scheduleReconnect(reason: reason)
                    }
                }
            }
        }
    }

    private func scheduleConnectTimeout(for task: URLSessionWebSocketTask) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.webSocketConnectTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            guard self.webSocketTask === task else { return }
            guard self.webSocketConnectionState == .connecting else { return }
            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.webSocketPingTask?.cancel()
            self.webSocketPingTask = nil
            self.webSocketTask = nil
            self.currentWebSocketSessionID = nil
            self.failPendingControlCommands(TurboBackendError.webSocketUnavailable)
            self.setWebSocketConnectionState(.idle)
            task.cancel(with: .goingAway, reason: nil)
            self.onServerNotice?("WebSocket connect timed out")
            self.connectTimeoutTask = nil
            self.scheduleReconnect(reason: "WebSocket connect timed out")
        }
    }

    static func presenceLookupPath(for handle: String) -> String {
        let escapedHandle = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        return "/v1/users/by-handle/\(escapedHandle)/presence"
    }

    private func controlCommandRequest<Response: Decodable>(
        path: String,
        body: TurboControlCommandEnvelope
    ) async throws -> Response {
        let requestStartedAt = DispatchTime.now().uptimeNanoseconds
        if let runtimeTransport = selectedPersistentRuntimeControlTransport {
            do {
                return try decodeControlCommandResponse(
                    try await controlCommandData(
                        path: path,
                        body: body,
                        transport: runtimeTransport,
                        requestStartedAt: requestStartedAt
                    ),
                    body: body,
                    transport: runtimeTransport
                )
            } catch {
                onServerNotice?(
                    "\(runtimeTransport.label) command failed; using HTTP fallback: \(error.localizedDescription)"
                )
            }
        }
        if canAttemptWebSocketControlCommand {
            do {
                return try await webSocketControlCommand(body)
            } catch {
                onServerNotice?("WebSocket command failed; using HTTP fallback: \(error.localizedDescription)")
            }
        }
        return try await request(path: path, method: "POST", body: body)
    }

    private enum ControlCommandTransport {
        case runtimeQuic
        case runtimeTls
        case webSocket
        case http

        var label: String {
            switch self {
            case .runtimeQuic:
                return "Runtime QUIC"
            case .runtimeTls:
                return "Runtime TLS"
            case .webSocket:
                return "WebSocket"
            case .http:
                return "HTTP"
            }
        }

        var trace: ControlCommandTransportTrace {
            switch self {
            case .runtimeQuic:
                return .runtimeQuic
            case .runtimeTls:
                return .runtimeTls
            case .webSocket:
                return .webSocket
            case .http:
                return .http
            }
        }

        var runtimeLane: TurboRuntimeControlLane? {
            switch self {
            case .runtimeQuic:
                return .runtimeQuicControl
            case .runtimeTls:
                return .runtimeTlsControl
            case .webSocket, .http:
                return nil
            }
        }

        static func persistentRuntime(_ lane: TurboRuntimeControlLane) -> ControlCommandTransport? {
            switch lane {
            case .runtimeQuicControl:
                return .runtimeQuic
            case .runtimeTlsControl:
                return .runtimeTls
            case .runtimeHttpRequest:
                return nil
            }
        }
    }

    private var selectedPersistentRuntimeControlTransport: ControlCommandTransport? {
        let selection = runtimeControlSelection
        guard selection.usesPersistentTransport else { return nil }
        guard let transport = ControlCommandTransport.persistentRuntime(selection.effectiveLane) else {
            return nil
        }
        guard canAttemptRuntimePersistentControlCommand(transport) else { return nil }
        return transport
    }

    private func hedgedControlCommandRequest<Response: Decodable>(
        path: String,
        body: TurboControlCommandEnvelope
    ) async throws -> Response {
        let requestStartedAt = DispatchTime.now().uptimeNanoseconds
        if let runtimeTransport = selectedPersistentRuntimeControlTransport {
            do {
                return try decodeControlCommandResponse(
                    try await controlCommandData(
                        path: path,
                        body: body,
                        transport: runtimeTransport,
                        requestStartedAt: requestStartedAt
                    ),
                    body: body,
                    transport: runtimeTransport
                )
            } catch {
                emitControlCommandTrace(
                    commandKind: body.commandKind,
                    transport: .http,
                    phase: .hedgeStarted,
                    operationId: body.operationId,
                    channelId: body.channelId,
                    requestId: nil,
                    startedAtNanoseconds: requestStartedAt,
                    detail: "\(runtimeTransport.trace.rawValue)-failed"
                )
                onServerNotice?(
                    "\(runtimeTransport.label) \(body.commandKind) failed; using HTTP fallback: \(error.localizedDescription)"
                )
                return try decodeControlCommandResponse(
                    try await controlCommandData(
                        path: path,
                        body: body,
                        transport: .http,
                        requestStartedAt: requestStartedAt
                    ),
                    body: body,
                    transport: .http
                )
            }
        }
        guard canAttemptWebSocketControlCommand else {
            return try decodeControlCommandResponse(
                try await controlCommandData(
                    path: path,
                    body: body,
                    transport: .http,
                    requestStartedAt: requestStartedAt
                ),
                body: body,
                transport: .http
            )
        }

        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask { @MainActor in
                try self.decodeControlCommandResponse(
                    try await self.controlCommandData(
                        path: path,
                        body: body,
                        transport: .webSocket,
                        requestStartedAt: requestStartedAt
                    ),
                    body: body,
                    transport: .webSocket
                )
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: self.controlCommandHedgeDelayNanoseconds)
                self.emitControlCommandTrace(
                    commandKind: body.commandKind,
                    transport: .http,
                    phase: .hedgeStarted,
                    operationId: body.operationId,
                    channelId: body.channelId,
                    requestId: nil,
                    startedAtNanoseconds: requestStartedAt,
                    detail: "websocket-slow"
                )
                self.onServerNotice?("WebSocket \(body.commandKind) slow; hedging over HTTP")
                return try self.decodeControlCommandResponse(
                    try await self.controlCommandData(
                        path: path,
                        body: body,
                        transport: .http,
                        requestStartedAt: requestStartedAt
                    ),
                    body: body,
                    transport: .http
                )
            }

            var lastError: Error?
            while true {
                do {
                    guard let response = try await group.next() else { break }
                    group.cancelAll()
                    return response
                } catch {
                    lastError = error
                }
            }

            throw lastError ?? TurboBackendError.invalidResponse
        }
    }

    private func hedgedPresenceCommandRequest<Response: Decodable>(
        path: String,
        commandKind: String,
        httpFallbackDelayNanoseconds: UInt64
    ) async throws -> Response {
        let envelope = TurboControlCommandEnvelope(
            commandKind: commandKind,
            userHandle: config.devUserHandle,
            deviceId: config.deviceID
        )
        let requestStartedAt = DispatchTime.now().uptimeNanoseconds
        if let runtimeTransport = selectedPersistentRuntimeControlTransport {
            do {
                return try decodeControlCommandResponse(
                    try await controlCommandData(
                        path: path,
                        body: envelope,
                        transport: runtimeTransport,
                        requestStartedAt: requestStartedAt
                    ),
                    body: envelope,
                    transport: runtimeTransport
                )
            } catch {
                emitControlCommandTrace(
                    commandKind: envelope.commandKind,
                    transport: .http,
                    phase: .hedgeStarted,
                    operationId: envelope.operationId,
                    channelId: envelope.channelId,
                    requestId: nil,
                    startedAtNanoseconds: requestStartedAt,
                    detail: "\(runtimeTransport.trace.rawValue)-failed"
                )
                onServerNotice?(
                    "\(runtimeTransport.label) \(envelope.commandKind) failed; using HTTP fallback: \(error.localizedDescription)"
                )
                return try decodeControlCommandResponse(
                    try await controlCommandData(
                        path: path,
                        body: envelope,
                        transport: .http,
                        requestStartedAt: requestStartedAt
                    ),
                    body: envelope,
                    transport: .http
                )
            }
        }
        guard canSendPresenceCommandsOverWebSocket else {
            return try decodeControlCommandResponse(
                try await controlCommandData(
                    path: path,
                    body: envelope,
                    transport: .http,
                    requestStartedAt: requestStartedAt
                ),
                body: envelope,
                transport: .http
            )
        }

        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask { @MainActor in
                try self.decodeControlCommandResponse(
                    try await self.webSocketPresenceCommandData(
                        envelope,
                        requestStartedAt: requestStartedAt
                    ),
                    body: envelope,
                    transport: .webSocket
                )
            }
            group.addTask { @MainActor in
                if httpFallbackDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: httpFallbackDelayNanoseconds)
                }
                let fallbackDetail = httpFallbackDelayNanoseconds == 0
                    ? "immediate-http-fallback"
                    : "websocket-slow"
                self.emitControlCommandTrace(
                    commandKind: envelope.commandKind,
                    transport: .http,
                    phase: .hedgeStarted,
                    operationId: envelope.operationId,
                    channelId: envelope.channelId,
                    requestId: nil,
                    startedAtNanoseconds: requestStartedAt,
                    detail: fallbackDetail
                )
                if httpFallbackDelayNanoseconds == 0 {
                    self.onServerNotice?("WebSocket \(envelope.commandKind) using immediate HTTP fallback")
                } else {
                    self.onServerNotice?("WebSocket \(envelope.commandKind) slow; hedging over HTTP")
                }
                return try self.decodeControlCommandResponse(
                    try await self.controlCommandData(
                        path: path,
                        body: envelope,
                        transport: .http,
                        requestStartedAt: requestStartedAt
                    ),
                    body: envelope,
                    transport: .http
                )
            }

            var lastError: Error?
            while true {
                do {
                    guard let response = try await group.next() else { break }
                    group.cancelAll()
                    return response
                } catch {
                    lastError = error
                }
            }

            throw lastError ?? TurboBackendError.invalidResponse
        }
    }

    private var canAttemptWebSocketControlCommand: Bool {
        guard !controlCommandTransportPolicy.disablesWebSocketCompatibility else { return false }
        guard supportsWebSocket, webSocketConnectionState == .connected else { return false }
        return webSocketTask != nil
            || currentWebSocketSessionID != nil
            || controlCommandWebSocketResponseForTesting != nil
    }

    private func canAttemptRuntimePersistentControlCommand(_ transport: ControlCommandTransport) -> Bool {
        guard let lane = transport.runtimeLane else { return false }
        if controlCommandRuntimePersistentResponseForTesting != nil {
            return true
        }
        guard runtimeControlEndpoint(for: lane) != nil else { return false }
        switch lane {
        case .runtimeQuicControl:
            return supportsRuntimeQuicControl && runtimeConfig?.runtimeControl?.quic?.supported == true
        case .runtimeTlsControl:
            return supportsRuntimeTlsControl && runtimeConfig?.runtimeControl?.tls?.supported == true
        case .runtimeHttpRequest:
            return false
        }
    }

    private func controlCommandData(
        path: String,
        body: TurboControlCommandEnvelope,
        transport: ControlCommandTransport,
        requestStartedAt: UInt64
    ) async throws -> Data {
        emitControlCommandTrace(
            commandKind: body.commandKind,
            transport: transport.trace,
            phase: .started,
            operationId: body.operationId,
            channelId: body.channelId,
            requestId: nil,
            startedAtNanoseconds: requestStartedAt,
            detail: nil
        )

        do {
            let data: Data
            switch transport {
            case .runtimeQuic, .runtimeTls:
                data = try await runtimePersistentControlCommandData(
                    body,
                    transport: transport,
                    requestStartedAt: requestStartedAt
                )
            case .webSocket:
                data = try await webSocketControlCommandData(
                    body,
                    requestStartedAt: requestStartedAt
                )
            case .http:
                if let controlCommandHTTPResponseForTesting {
                    data = try await controlCommandHTTPResponseForTesting(path, body)
                } else {
                    data = try await requestData(path: path, method: "POST", body: body)
                }
            }
            emitControlCommandTrace(
                commandKind: body.commandKind,
                transport: transport.trace,
                phase: .responseReceived,
                operationId: body.operationId,
                channelId: body.channelId,
                requestId: nil,
                startedAtNanoseconds: requestStartedAt,
                detail: nil
            )
            return data
        } catch {
            emitControlCommandTrace(
                commandKind: body.commandKind,
                transport: transport.trace,
                phase: .failed,
                operationId: body.operationId,
                channelId: body.channelId,
                requestId: nil,
                startedAtNanoseconds: requestStartedAt,
                detail: error.localizedDescription
            )
            throw error
        }
    }

    private func emitControlCommandTrace(
        commandKind: String,
        transport: ControlCommandTransportTrace,
        phase: ControlCommandTracePhase,
        operationId: String?,
        channelId: String?,
        requestId: String?,
        startedAtNanoseconds: UInt64?,
        detail: String?
    ) {
        let elapsedMs = startedAtNanoseconds.map { startedAt in
            Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        }
        onControlCommandTrace?(
            ControlCommandTraceEvent(
                commandKind: commandKind,
                transport: transport,
                phase: phase,
                operationId: operationId,
                channelId: channelId,
                requestId: requestId,
                elapsedMs: elapsedMs,
                detail: detail
            )
        )
    }

    private func runtimePersistentControlCommandData(
        _ envelope: TurboControlCommandEnvelope,
        transport: ControlCommandTransport,
        requestStartedAt: UInt64
    ) async throws -> Data {
        guard let lane = transport.runtimeLane else {
            throw TurboBackendError.invalidConfiguration
        }

        let requestID = UUID().uuidString.lowercased()
        if let controlCommandRuntimePersistentResponseForTesting {
            let frameData = try await controlCommandRuntimePersistentResponseForTesting(lane, envelope)
            return try decodeRuntimeControlResponseBody(
                frameData,
                requestID: nil,
                body: envelope,
                transport: transport
            )
        }

        guard let endpoint = runtimeControlEndpoint(for: lane) else {
            throw TurboBackendError.invalidConfiguration
        }

        let frameData = try runtimeControlFrameData(for: envelope, requestID: requestID)
        let connection = try await activeRuntimeControlConnection(
            lane: lane,
            endpoint: endpoint,
            identity: RuntimeControlConnectionIdentity(
                userHandle: envelope.userHandle,
                deviceID: envelope.deviceId
            )
        )
        do {
            try await sendRuntimeControlFrame(frameData, on: connection)
            emitControlCommandTrace(
                commandKind: envelope.commandKind,
                transport: transport.trace,
                phase: .sendCompleted,
                operationId: envelope.operationId,
                channelId: envelope.channelId,
                requestId: requestID,
                startedAtNanoseconds: requestStartedAt,
                detail: nil
            )
            let responseData = try await receiveRuntimeControlLine(on: connection)
            return try decodeRuntimeControlResponseBody(
                responseData,
                requestID: requestID,
                body: envelope,
                transport: transport
            )
        } catch {
            invalidateRuntimeControlConnection(connection)
            throw error
        }
    }

    private func runtimeControlFrameData(
        for envelope: TurboControlCommandEnvelope,
        requestID: String
    ) throws -> Data {
        let frame = TurboRuntimeControlCommandRequest(
            requestId: requestID,
            sessionId: currentWebSocketSessionID,
            envelope: envelope
        )
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        return data
    }

    private func decodeRuntimeControlResponseBody(
        _ data: Data,
        requestID: String?,
        body: TurboControlCommandEnvelope,
        transport: ControlCommandTransport
    ) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TurboBackendError.invalidResponseDetails(
                "\(transport.label) \(body.commandKind) returned a non-object runtime control frame"
            )
        }
        guard let type = object["type"] as? String,
              type == "control-command-response" || type == "presence-command-response" else {
            let returnedType = object["type"] as? String ?? "missing-type"
            let message = object["error"] as? String
                ?? (object["body"] as? [String: Any])?["error"] as? String
                ?? "missing-error"
            throw TurboBackendError.invalidResponseDetails(
                "\(transport.label) \(body.commandKind) returned unexpected runtime control frame \(returnedType): \(message)"
            )
        }
        if let requestID,
           let responseRequestID = object["requestId"] as? String,
           responseRequestID != requestID {
            throw TurboBackendError.invalidResponseDetails(
                "\(transport.label) \(body.commandKind) response requestId mismatch"
            )
        }
        guard object["status"] as? String == "ok" else {
            let message = object["error"] as? String
                ?? (object["body"] as? [String: Any])?["error"] as? String
                ?? "\(transport.label) command failed"
            throw TurboBackendError.server(message)
        }
        guard let responseBody = object["body"],
              JSONSerialization.isValidJSONObject(responseBody) else {
            throw TurboBackendError.invalidResponseDetails(
                "\(transport.label) \(body.commandKind) response frame did not include a JSON body"
            )
        }
        return try JSONSerialization.data(withJSONObject: responseBody)
    }

    private struct RuntimeControlEndpoint: Equatable {
        let host: String
        let port: UInt16
    }

    private struct RuntimeControlConnection {
        let lane: TurboRuntimeControlLane
        let endpoint: RuntimeControlEndpoint
        let identity: RuntimeControlConnectionIdentity
        let connection: NWConnection
    }

    private struct RuntimeControlConnectionIdentity: Equatable {
        let userHandle: String?
        let deviceID: String
    }

    private func runtimeControlEndpoint(for lane: TurboRuntimeControlLane) -> RuntimeControlEndpoint? {
        let endpoint: String?
        switch lane {
        case .runtimeQuicControl:
            endpoint = runtimeConfig?.runtimeControl?.quic?.endpoint
        case .runtimeTlsControl:
            endpoint = runtimeConfig?.runtimeControl?.tls?.endpoint
        case .runtimeHttpRequest:
            endpoint = nil
        }
        guard let endpoint else { return nil }
        return parseRuntimeControlEndpoint(endpoint)
    }

    private func parseRuntimeControlEndpoint(_ rawEndpoint: String) -> RuntimeControlEndpoint? {
        let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           let host = url.host,
           !host.isEmpty {
            return RuntimeControlEndpoint(host: host, port: UInt16(url.port ?? 443))
        }
        if trimmed.hasPrefix("["),
           let closeBracket = trimmed.firstIndex(of: "]") {
            let hostStart = trimmed.index(after: trimmed.startIndex)
            let host = String(trimmed[hostStart ..< closeBracket])
            let afterBracket = trimmed.index(after: closeBracket)
            if afterBracket < trimmed.endIndex,
               trimmed[afterBracket] == ":" {
                let portStart = trimmed.index(after: afterBracket)
                if let port = UInt16(trimmed[portStart...]) {
                    return RuntimeControlEndpoint(host: host, port: port)
                }
            }
            return RuntimeControlEndpoint(host: host, port: 443)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2,
           let port = UInt16(parts[1]) {
            return RuntimeControlEndpoint(host: String(parts[0]), port: port)
        }
        return RuntimeControlEndpoint(host: trimmed, port: 443)
    }

    private func runtimeControlParameters(for lane: TurboRuntimeControlLane) -> NWParameters {
        switch lane {
        case .runtimeQuicControl:
            let alpn = runtimeConfig?.runtimeControl?.quic?.alpn ?? "beep-runtime-control-v1"
            let quicOptions = NWProtocolQUIC.Options(alpn: [alpn])
            sec_protocol_options_set_min_tls_protocol_version(
                quicOptions.securityProtocolOptions,
                .TLSv13
            )
            let parameters = NWParameters(quic: quicOptions)
            parameters.includePeerToPeer = false
            return parameters
        case .runtimeTlsControl:
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(
                tlsOptions.securityProtocolOptions,
                .TLSv13
            )
            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            parameters.includePeerToPeer = false
            return parameters
        case .runtimeHttpRequest:
            return .tcp
        }
    }

    private func activeRuntimeControlConnection(
        lane: TurboRuntimeControlLane,
        endpoint: RuntimeControlEndpoint,
        identity: RuntimeControlConnectionIdentity
    ) async throws -> NWConnection {
        if let runtimeControlConnection,
           runtimeControlConnection.lane == lane,
           runtimeControlConnection.endpoint == endpoint,
           runtimeControlConnection.identity == identity {
            return runtimeControlConnection.connection
        }

        invalidateRuntimeControlConnection()
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port) ?? .https,
            using: runtimeControlParameters(for: lane)
        )
        try await startRuntimeControlConnection(connection)
        runtimeControlConnection = RuntimeControlConnection(
            lane: lane,
            endpoint: endpoint,
            identity: identity,
            connection: connection
        )
        return connection
    }

    private func invalidateRuntimeControlConnection(_ connection: NWConnection? = nil) {
        guard let existing = runtimeControlConnection else { return }
        guard connection == nil || existing.connection === connection else { return }
        runtimeControlConnection = nil
        existing.connection.cancel()
    }

    private func startRuntimeControlConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = TurboRuntimeControlContinuationGate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resumeOnce(.success(()), continuation: continuation)
                case .failed(let error):
                    gate.resumeOnce(.failure(error), continuation: continuation)
                case .cancelled:
                    gate.resumeOnce(.failure(CancellationError()), continuation: continuation)
                case .waiting(let error):
                    gate.resumeOnce(.failure(error), continuation: continuation)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: runtimeControlQueue)
        }
    }

    private func sendRuntimeControlFrame(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func receiveRuntimeControlLine(on connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while true {
            let chunk = try await receiveRuntimeControlChunk(on: connection)
            if !chunk.isEmpty {
                buffer.append(chunk)
            }
            if let newline = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[..<newline])
            }
            if buffer.count > 1_048_576 {
                throw TurboBackendError.invalidResponseDetails("Runtime control response exceeded 1 MiB")
            }
        }
    }

    private func receiveRuntimeControlChunk(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: TurboBackendError.invalidResponse)
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private func webSocketControlCommandData(
        _ envelope: TurboControlCommandEnvelope,
        requestStartedAt: UInt64
    ) async throws -> Data {
        if let controlCommandWebSocketResponseForTesting {
            return try await controlCommandWebSocketResponseForTesting(envelope)
        }

        guard supportsWebSocket,
              webSocketConnectionState == .connected,
              let webSocketTask else {
            throw TurboBackendError.webSocketUnavailable
        }

        let requestID = UUID().uuidString.lowercased()
        let frame = TurboControlCommandWebSocketRequest(
            requestId: requestID,
            sessionId: currentWebSocketSessionID,
            envelope: envelope
        )
        let data = try JSONEncoder().encode(frame)
        let text = String(decoding: data, as: UTF8.self)

        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingControlCommandResponses[requestID] = continuation
                pendingControlCommandKinds[requestID] = envelope.commandKind
                Task { @MainActor [weak self] in
                    do {
                        try await webSocketTask.send(.string(text))
                        self?.emitControlCommandTrace(
                            commandKind: envelope.commandKind,
                            transport: .webSocket,
                            phase: .sendCompleted,
                            operationId: envelope.operationId,
                            channelId: envelope.channelId,
                            requestId: requestID,
                            startedAtNanoseconds: requestStartedAt,
                            detail: nil
                        )
                    } catch {
                        self?.finishPendingControlCommand(requestID, result: .failure(error))
                    }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: self?.webSocketControlCommandTimeoutNanoseconds ?? 3_000_000_000)
                    self?.finishPendingControlCommand(requestID, result: .failure(TurboBackendError.webSocketUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPendingControlCommand(requestID, result: .failure(CancellationError()))
            }
        }

        return responseData
    }

    private func webSocketPresenceCommandData(
        _ envelope: TurboControlCommandEnvelope,
        requestStartedAt: UInt64
    ) async throws -> Data {
        if let controlCommandWebSocketResponseForTesting {
            return try await controlCommandWebSocketResponseForTesting(envelope)
        }

        guard supportsWebSocket,
              webSocketConnectionState == .connected,
              !webSocketPresenceCommandsRejected,
              let webSocketTask else {
            throw TurboBackendError.webSocketUnavailable
        }

        let requestID = UUID().uuidString.lowercased()
        let frame = TurboPresenceCommandWebSocketRequest(
            requestId: requestID,
            sessionId: currentWebSocketSessionID,
            envelope: envelope
        )
        let data = try JSONEncoder().encode(frame)
        let text = String(decoding: data, as: UTF8.self)

        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingControlCommandResponses[requestID] = continuation
                pendingControlCommandKinds[requestID] = envelope.commandKind
                Task { @MainActor [weak self] in
                    do {
                        try await webSocketTask.send(.string(text))
                        self?.emitControlCommandTrace(
                            commandKind: envelope.commandKind,
                            transport: .webSocket,
                            phase: .sendCompleted,
                            operationId: envelope.operationId,
                            channelId: envelope.channelId,
                            requestId: requestID,
                            startedAtNanoseconds: requestStartedAt,
                            detail: nil
                        )
                    } catch {
                        self?.finishPendingControlCommand(requestID, result: .failure(error))
                    }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        nanoseconds: self?.webSocketControlCommandTimeoutNanoseconds ?? 3_000_000_000
                    )
                    self?.finishPendingControlCommand(
                        requestID,
                        result: .failure(TurboBackendError.webSocketUnavailable)
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPendingControlCommand(
                    requestID,
                    result: .failure(CancellationError())
                )
            }
        }

        return responseData
    }

    private func decodeControlCommandResponse<Response: Decodable>(
        _ data: Data,
        body: TurboControlCommandEnvelope,
        transport: ControlCommandTransport
    ) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            throw TurboBackendError.invalidResponseDetails(
                "\(transport.label) \(body.commandKind) decode failed: \(error.localizedDescription) body=\(responseBody)"
            )
        }
    }

    private func webSocketControlCommand<Response: Decodable>(
        _ envelope: TurboControlCommandEnvelope
    ) async throws -> Response {
        let responseData = try await webSocketControlCommandData(
            envelope,
            requestStartedAt: DispatchTime.now().uptimeNanoseconds
        )
        return try decodeControlCommandResponse(responseData, body: envelope, transport: .webSocket)
    }

    private func handleWebSocketCommandResponseData(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              type == "control-command-response" || type == "presence-command-response" else {
            return false
        }
        guard let requestID = object["requestId"] as? String else {
            onServerNotice?("Received websocket command response without requestId")
            return true
        }
        guard object["status"] as? String == "ok" else {
            let message = object["error"] as? String ?? "websocket command failed"
            finishPendingControlCommand(requestID, result: .failure(TurboBackendError.server(message)))
            return true
        }
        guard let body = object["body"],
              JSONSerialization.isValidJSONObject(body),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            finishPendingControlCommand(requestID, result: .failure(TurboBackendError.invalidResponse))
            return true
        }
        finishPendingControlCommand(requestID, result: .success(bodyData))
        return true
    }

    private func finishPendingControlCommand(_ requestID: String, result: Result<Data, Error>) {
        guard let continuation = pendingControlCommandResponses.removeValue(forKey: requestID) else { return }
        pendingControlCommandKinds.removeValue(forKey: requestID)
        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func handleWebSocketErrorNotice(_ message: String) {
        guard message == "invalid signaling payload" else { return }
        let rejectedPresenceRequests = pendingControlCommandKinds.compactMap { requestID, commandKind in
            commandKind.hasPrefix("presence-") ? requestID : nil
        }
        guard !rejectedPresenceRequests.isEmpty else { return }
        webSocketPresenceCommandsRejected = true
        for requestID in rejectedPresenceRequests {
            finishPendingControlCommand(requestID, result: .failure(TurboBackendError.webSocketUnavailable))
        }
    }

    private func failPendingControlCommands(_ error: Error) {
        let pending = pendingControlCommandResponses
        pendingControlCommandResponses = [:]
        pendingControlCommandKinds = [:]
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String = "GET",
        body: Body? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        let data = try await requestData(
            path: path,
            method: method,
            body: body,
            timeoutInterval: timeoutInterval
        )
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            onServerNotice?("Invalid response for \(method) \(path): \(error.localizedDescription) body=\(responseBody)")
            throw TurboBackendError.invalidResponseDetails(
                "\(method) \(path) decode failed: \(error.localizedDescription) body=\(responseBody)"
            )
        }
    }

    private func requestData<Body: Encodable>(
        path: String,
        method: String = "GET",
        body: Body? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Data {
        let url = config.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        request.addValue(config.devUserHandle, forHTTPHeaderField: "x-turbo-user-handle")
        request.addValue("Bearer \(config.devUserHandle)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TurboBackendError.invalidResponse
        }

        if 200 ..< 300 ~= http.statusCode {
            return data
        }

        if let error = try? JSONDecoder().decode(TurboErrorResponse.self, from: data) {
            throw TurboBackendError.server(error.error)
        }

        throw TurboBackendError.server(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET"
    ) async throws -> Response {
        try await request(path: path, method: method, body: Optional<TurboEmptyRequest>.none as TurboEmptyRequest?)
    }
}

private struct TurboEmptyRequest: Encodable {}

private nonisolated final class TurboRuntimeControlContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(
        _ result: Result<Void, Error>,
        continuation: CheckedContinuation<Void, Error>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private struct TurboRegisterDeviceRequest: Encodable {
    let deviceId: String
    let deviceLabel: String?
    let alertPushToken: String?
    let alertPushEnvironment: String?
    let directQuicIdentity: DirectQuicIdentityRegistrationMetadata?
    let mediaEncryptionIdentity: MediaEncryptionIdentityRegistrationMetadata?
}

private struct TurboDirectChannelRequest: Encodable {
    let otherHandle: String?
    let otherUserId: String?
}

struct TurboControlCommandEnvelope: Encodable {
    let commandKind: String
    let userHandle: String?
    let deviceId: String
    let operationId: String?
    let channelId: String?
    let contactId: String?
    let friendHandle: String?
    let friendUserId: String?
    let otherHandle: String?
    let otherUserId: String?
    let transmitId: String?
    let subject: String?
    let deviceSessionProof: String?

    init(
        commandKind: String,
        userHandle: String? = nil,
        deviceId: String,
        operationId: String? = nil,
        channelId: String? = nil,
        contactId: String? = nil,
        friendHandle: String? = nil,
        friendUserId: String? = nil,
        otherHandle: String? = nil,
        otherUserId: String? = nil,
        transmitId: String? = nil,
        subject: String? = nil,
        deviceSessionProof: String? = nil
    ) {
        self.commandKind = commandKind
        self.userHandle = userHandle
        self.deviceId = deviceId
        self.operationId = operationId
        self.channelId = channelId
        self.contactId = contactId
        self.friendHandle = friendHandle
        self.friendUserId = friendUserId
        self.otherHandle = otherHandle
        self.otherUserId = otherUserId
        self.transmitId = transmitId
        self.subject = subject
        self.deviceSessionProof = deviceSessionProof
    }
}

private struct TurboControlCommandWebSocketRequest: Encodable {
    let type = "control-command"
    let requestId: String
    let sessionId: String?
    let commandKind: String
    let userHandle: String?
    let deviceId: String
    let operationId: String?
    let channelId: String?
    let contactId: String?
    let otherHandle: String?
    let otherUserId: String?
    let transmitId: String?

    init(
        requestId: String,
        sessionId: String?,
        envelope: TurboControlCommandEnvelope
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        commandKind = envelope.commandKind
        userHandle = envelope.userHandle
        deviceId = envelope.deviceId
        operationId = envelope.operationId
        channelId = envelope.channelId
        contactId = envelope.contactId
        otherHandle = envelope.otherHandle
        otherUserId = envelope.otherUserId
        transmitId = envelope.transmitId
    }
}

private struct TurboPresenceCommandWebSocketRequest: Encodable {
    let type = "presence-command"
    let requestId: String
    let sessionId: String?
    let commandKind: String
    let userHandle: String?
    let deviceId: String

    init(
        requestId: String,
        sessionId: String?,
        envelope: TurboControlCommandEnvelope
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        commandKind = envelope.commandKind
        userHandle = envelope.userHandle
        deviceId = envelope.deviceId
    }
}

private struct TurboRuntimeControlCommandRequest: Encodable {
    let type: String
    let requestId: String
    let sessionId: String?
    let commandKind: String
    let userHandle: String?
    let deviceId: String
    let operationId: String?
    let channelId: String?
    let contactId: String?
    let friendHandle: String?
    let friendUserId: String?
    let otherHandle: String?
    let otherUserId: String?
    let transmitId: String?
    let subject: String?
    let deviceSessionProof: String?

    init(
        requestId: String,
        sessionId: String?,
        envelope: TurboControlCommandEnvelope
    ) {
        self.type = envelope.commandKind.hasPrefix("presence-")
            ? "presence-command"
            : "control-command"
        self.requestId = requestId
        self.sessionId = sessionId
        commandKind = envelope.commandKind
        userHandle = envelope.userHandle
        deviceId = envelope.deviceId
        operationId = envelope.operationId
        channelId = envelope.channelId
        contactId = envelope.contactId
        friendHandle = envelope.friendHandle
        friendUserId = envelope.friendUserId
        otherHandle = envelope.otherHandle
        otherUserId = envelope.otherUserId
        transmitId = envelope.transmitId
        subject = envelope.subject
        deviceSessionProof = envelope.deviceSessionProof
    }
}

private struct TurboResolveIdentityRequest: Encodable {
    let reference: String
}

private struct TurboRememberContactRequest: Encodable {
    let otherHandle: String?
    let otherUserId: String?
}

private struct TurboForgetContactRequest: Encodable {
    let otherHandle: String?
    let otherUserId: String?
}

private struct TurboChannelDeviceRequest: Encodable {
    let deviceId: String
    let transmitId: String?

    init(deviceId: String, transmitId: String? = nil) {
        self.deviceId = deviceId
        self.transmitId = transmitId
    }
}

struct TurboBeginTransmitLeaseRequest: Encodable, Equatable, Sendable {
    let deviceId: String
    let requestingParticipantId: String
    let requestingSessionEpoch: UInt64
    let targetParticipantId: String
    let operationId: String
    let policyVersion: String
    let kernelVersion: String

    init(
        deviceId: String,
        requestingParticipantId: String,
        requestingSessionEpoch: UInt64 = 0,
        targetParticipantId: String,
        operationId: String,
        policyVersion: String = "policy-v1",
        kernelVersion: String = "kernel-contract-v1"
    ) {
        self.deviceId = deviceId
        self.requestingParticipantId = requestingParticipantId
        self.requestingSessionEpoch = requestingSessionEpoch
        self.targetParticipantId = targetParticipantId
        self.operationId = operationId
        self.policyVersion = policyVersion
        self.kernelVersion = kernelVersion
    }
}

private struct TurboDeviceOnlyRequest: Encodable {
    let deviceId: String
}

struct TurboReceiverAudioReadinessRequest: Encodable, Equatable {
    let deviceId: String
    let type: String
    let payload: String
}

private struct TurboEphemeralTokenRequest: Encodable {
    let deviceId: String
    let token: String
    let apnsEnvironment: String
}
