import Foundation

enum BeepNotificationIntentAction: String, Equatable {
    case open
    case accept
    case notNow
}

struct BeepNotificationIntent: Equatable {
    let action: BeepNotificationIntentAction
    let beepID: String?
    let handle: String
    let channelID: String?
    let subject: String?
    let sentAt: String?
    let deepLink: URL?

    init?(
        action: BeepNotificationIntentAction,
        userInfo: [AnyHashable: Any]
    ) {
        guard let handle = userInfo["fromHandle"] as? String,
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        self.action = action
        self.beepID = userInfo["beepId"] as? String
        self.handle = handle
        self.channelID = userInfo["channelId"] as? String
        self.subject = userInfo["subject"] as? String
        self.sentAt = (userInfo["sentAt"] as? String) ?? (userInfo["createdAt"] as? String)
        self.deepLink = (userInfo["deepLink"] as? String).flatMap(URL.init(string:))
    }

    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "event": TurboNotificationCategory.beepEvent,
            "fromHandle": handle,
        ]
        if let beepID {
            info["beepId"] = beepID
        }
        if let channelID {
            info["channelId"] = channelID
        }
        if let subject {
            info["subject"] = subject
        }
        if let sentAt {
            info["sentAt"] = sentAt
        }
        if let deepLink {
            info["deepLink"] = deepLink.absoluteString
        }
        return info
    }
}

enum ConversationOpenIntentAction: String, Equatable {
    case open
    case accept
    case end
}

struct ConversationOpenIntent: Equatable {
    let reference: String
    let beepID: String?
    let channelID: String?
    let action: ConversationOpenIntentAction

    init?(
        reference: String?,
        beepID: String? = nil,
        channelID: String? = nil,
        action: ConversationOpenIntentAction = .open
    ) {
        guard let reference,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.reference = reference
        self.beepID = beepID
        self.channelID = channelID
        self.action = action
    }
}
