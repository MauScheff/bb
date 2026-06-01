import Foundation

enum DevSelfCheckStatus: String, Equatable {
    case passed
    case failed
    case skipped
}

enum DevSelfCheckStepID: String, Equatable, CaseIterable {
    case backendConfig = "backend-config"
    case microphonePermission = "microphone-permission"
    case runtimeConfig = "runtime-config"
    case authSession = "auth-session"
    case deviceHeartbeat = "device-heartbeat"
    case websocket = "websocket"
    case friendLookup = "friend-lookup"
    case directChannel = "direct-channel"
    case channelState = "channel-state"
    case sessionAlignment = "session-alignment"

    var title: String {
        switch self {
        case .backendConfig:
            return "Backend config"
        case .microphonePermission:
            return "Microphone permission"
        case .runtimeConfig:
            return "Runtime config"
        case .authSession:
            return "Auth session"
        case .deviceHeartbeat:
            return "Presence heartbeat"
        case .websocket:
            return "WebSocket"
        case .friendLookup:
            return "Friend lookup"
        case .directChannel:
            return "Direct channel"
        case .channelState:
            return "Channel state"
        case .sessionAlignment:
            return "Session alignment"
        }
    }
}

struct DevSelfCheckStep: Identifiable, Equatable {
    let id: DevSelfCheckStepID
    let status: DevSelfCheckStatus
    let detail: String

    init(_ id: DevSelfCheckStepID, status: DevSelfCheckStatus, detail: String) {
        self.id = id
        self.status = status
        self.detail = detail
    }
}

struct DevSelfCheckReport: Equatable {
    let startedAt: Date
    let completedAt: Date
    let targetHandle: String?
    let steps: [DevSelfCheckStep]

    var isPassing: Bool {
        !steps.contains(where: { $0.status == .failed })
    }

    var summary: String {
        if let failingStep = steps.first(where: { $0.status == .failed }) {
            return "Self-check failed at \(failingStep.id.title.lowercased())"
        }
        if let targetHandle {
            return "Self-check passed for \(targetHandle)"
        }
        return "Self-check passed"
    }
}
