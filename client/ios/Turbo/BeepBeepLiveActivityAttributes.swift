import ActivityKit
import Foundation

struct BeepBeepLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: BeepBeepLiveActivityPhase
        var speakerName: String?
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
}
