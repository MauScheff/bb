import Foundation

enum TurboTelemetrySeverity: String, Encodable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    init(diagnosticsLevel: DiagnosticsLevel) {
        switch diagnosticsLevel {
        case .debug:
            self = .debug
        case .info:
            self = .info
        case .notice:
            self = .notice
        case .error:
            self = .error
        }
    }
}

struct TurboTelemetryEventRequest: Encodable {
    let eventName: String
    let source: String
    let severity: String
    let userId: String?
    let userHandle: String?
    let deviceId: String?
    let sessionId: String?
    let channelId: String?
    let peerUserId: String?
    let peerDeviceId: String?
    let peerHandle: String?
    let appVersion: String?
    let backendVersion: String?
    let invariantId: String?
    let phase: String?
    let reason: String?
    let message: String?
    let metadataText: String?
    let devTraffic: String
    let alert: String

    init(
        eventName: String,
        source: String,
        severity: String,
        userId: String? = nil,
        userHandle: String? = nil,
        deviceId: String? = nil,
        sessionId: String? = nil,
        channelId: String? = nil,
        peerUserId: String? = nil,
        peerDeviceId: String? = nil,
        peerHandle: String? = nil,
        appVersion: String? = nil,
        backendVersion: String? = nil,
        invariantId: String? = nil,
        phase: String? = nil,
        reason: String? = nil,
        message: String? = nil,
        metadata: [String: String] = [:],
        metadataText: String? = nil,
        devTraffic: Bool = false,
        alert: Bool = false
    ) {
        self.eventName = eventName
        self.source = source
        self.severity = severity
        self.userId = userId
        self.userHandle = userHandle
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.channelId = channelId
        self.peerUserId = peerUserId
        self.peerDeviceId = peerDeviceId
        self.peerHandle = peerHandle
        self.appVersion = appVersion
        self.backendVersion = backendVersion
        self.invariantId = invariantId
        self.phase = phase
        self.reason = reason
        self.message = message
        self.metadataText = TurboTelemetryEventRequest.serializeMetadata(
            metadata: metadata,
            metadataText: metadataText
        )
        self.devTraffic = devTraffic ? "true" : "false"
        self.alert = alert ? "true" : "false"
    }

    private static func serializeMetadata(
        metadata: [String: String],
        metadataText: String?
    ) -> String? {
        if let metadataText, !metadataText.isEmpty {
            return metadataText
        }
        guard !metadata.isEmpty else { return nil }
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

enum DiagnosticsHighSignalEvent {
    case errorEntry(DiagnosticsEntry)
    case invariantViolation(DiagnosticsInvariantViolation)
}
