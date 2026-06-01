import ActivityKit
import Foundation

struct BeepBeepLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: BeepBeepLiveActivityPhase
        var speakerName: String?
        var canEnd: Bool
        var lastUpdatedAt: Date
    }

    var conversationID: String
    var contactHandle: String
    var contactName: String
    var startedAt: Date
}

enum BeepBeepLiveActivityPhase: String, Codable, Hashable {
    case connecting
    case connected
    case speaking
    case listening
    case reconnecting

    var statusText: String {
        switch self {
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .speaking:
            return "Speaking"
        case .listening:
            return "Listening"
        case .reconnecting:
            return "Reconnecting"
        }
    }
}
