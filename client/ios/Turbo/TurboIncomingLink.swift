import Foundation
import Intents

enum TurboIncomingLink {
    private static let shareHost = "beepbeep.to"
    private static let apiShareHost = "api.beepbeep.to"
    private static let didPrefix = "did:web:beepbeep.to:id:"
    private static let apiDidPrefix = "did:web:api.beepbeep.to:id:"
    private static let rootShareLinkPrefix = "https://beepbeep.to/"
    private static let apiRootShareLinkPrefix = "https://api.beepbeep.to/"
    private static let bareRootShareLinkPrefix = "beepbeep.to/"
    private static let bareAPIRootShareLinkPrefix = "api.beepbeep.to/"
    private static let handleShareLinkPrefix = "https://beepbeep.to/@"
    private static let apiHandleShareLinkPrefix = "https://api.beepbeep.to/@"
    private static let bareHandleShareLinkPrefix = "beepbeep.to/@"
    private static let bareAPIHandleShareLinkPrefix = "api.beepbeep.to/@"
    private static let legacyShareLinkPrefix = "https://beepbeep.to/p/"
    private static let apiLegacyShareLinkPrefix = "https://api.beepbeep.to/p/"
    private static let legacyBareShareLinkPrefix = "beepbeep.to/p/"
    private static let apiLegacyBareShareLinkPrefix = "api.beepbeep.to/p/"

    static func reference(from url: URL) -> String? {
        if let conversationIntent = conversationOpenIntent(from: url) {
            return conversationIntent.reference
        }

        guard let scheme = url.scheme?.lowercased() else { return nil }

        switch scheme {
        case "https", "http":
            return webReference(from: url)
        case "beepbeep":
            return customSchemeReference(from: url)
        default:
            return nil
        }
    }

    static func conversationOpenIntent(from url: URL) -> ConversationOpenIntent? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "beepbeep" || scheme == "https" || scheme == "http" else { return nil }

        let host = url.host?.lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let isConversationURL: Bool

        if scheme == "beepbeep" {
            isConversationURL = host == "conversation"
        } else {
            isConversationURL = isShareHost(host) && pathComponents.first == "conversation"
        }
        guard isConversationURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        func value(_ names: String...) -> String? {
            for name in names {
                if let itemValue = queryItems.first(where: { $0.name == name })?.value,
                   !itemValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return itemValue
                }
            }
            return nil
        }

        let reference = value("ref", "handle", "contact")
        let action = value("action").flatMap(ConversationOpenIntentAction.init(rawValue:)) ?? .open
        return ConversationOpenIntent(
            reference: reference,
            beepID: value("beepId"),
            channelID: value("channelId"),
            action: action
        )
    }

    static func conversationOpenIntent(fromStartCallUserActivity userActivity: NSUserActivity) -> ConversationOpenIntent? {
        guard userActivity.activityType == "INStartCallIntent",
              let startCallIntent = userActivity.interaction?.intent as? INStartCallIntent else {
            return nil
        }
        return conversationOpenIntent(fromStartCallIntent: startCallIntent)
    }

    static func conversationOpenIntent(fromStartCallIntent startCallIntent: INStartCallIntent) -> ConversationOpenIntent? {
        let reference =
            startCallIntent.contacts?.first?.personHandle?.value
        return ConversationOpenIntent(reference: reference, action: .accept)
    }

    private static func webReference(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), isShareHost(host) else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard !pathComponents.isEmpty else { return nil }

        if pathComponents.count == 1,
           let handle = canonicalHandle(fromPathComponent: pathComponents[0]) {
            return canonicalShareLink(for: handle, host: host)
        }

        guard pathComponents.count >= 2 else { return nil }

        switch (pathComponents[0], pathComponents[1]) {
        case ("p", let code) where !code.isEmpty:
            return canonicalShareLink(for: code, host: host)
        case ("id", let code) where !code.isEmpty:
            return "did:web:\(host):id:\(TurboHandle.normalizedStoredHandle(code))"
        default:
            return nil
        }
    }

    private static func customSchemeReference(from url: URL) -> String? {
        let host = url.host?.lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if host == "p", let code = pathComponents.first, !code.isEmpty {
            return canonicalShareLink(for: code)
        }

        if host == "id", let code = pathComponents.first, !code.isEmpty {
            return "did:web:\(shareHost):id:\(TurboHandle.normalizedStoredHandle(code))"
        }

        guard host == "add",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let reference = components.queryItems?.first(where: { $0.name == "ref" || $0.name == "code" })?.value,
              !reference.isEmpty else {
            return nil
        }

        return reference
    }

    private static func canonicalShareLink(for code: String, host: String = shareHost) -> String {
        let encodedHandle =
            TurboHandle.sharePathComponent(from: code)
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? TurboHandle.sharePathComponent(from: code)
        return "https://\(host)/\(encodedHandle)"
    }

    private static func isShareHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == shareHost || host == apiShareHost
    }

    private static func canonicalHandle(fromPathComponent component: String) -> String? {
        let canonical = TurboHandle.normalizedStoredHandle(component)
        let body = TurboHandle.body(from: canonical)
        guard !body.isEmpty, !TurboHandle.isReservedIdentityBody(body) else { return nil }
        return canonical.count > 1 ? canonical : nil
    }

    static func publicID(from reference: String) -> String? {
        guard let publicID = rawPublicID(from: reference) else { return nil }
        let body = TurboHandle.body(from: publicID)
        guard !TurboHandle.isReservedIdentityBody(body) else { return nil }
        let canonical = TurboHandle.normalizedStoredHandle(publicID)
        return canonical == "@" ? nil : canonical
    }

    static func isReservedIdentityReference(_ reference: String) -> Bool {
        guard let publicID = rawPublicID(from: reference) else {
            return TurboHandle.isReservedIdentityBody(TurboHandle.body(from: reference))
        }
        return TurboHandle.isReservedIdentityBody(TurboHandle.body(from: publicID))
    }

    private static func rawPublicID(from reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let normalizedReference = Self.reference(from: url),
           normalizedReference != trimmed {
            return rawPublicID(from: normalizedReference)
        }

        let normalized = trimmed.lowercased()
        let rawPublicID: String
        if normalized.hasPrefix(apiDidPrefix) {
            rawPublicID = String(normalized.dropFirst(apiDidPrefix.count))
        } else if normalized.hasPrefix(didPrefix) {
            rawPublicID = String(normalized.dropFirst(didPrefix.count))
        } else if normalized.hasPrefix(apiHandleShareLinkPrefix) {
            rawPublicID = "@\(String(normalized.dropFirst(apiHandleShareLinkPrefix.count)))"
        } else if normalized.hasPrefix(handleShareLinkPrefix) {
            rawPublicID = "@\(String(normalized.dropFirst(handleShareLinkPrefix.count)))"
        } else if normalized.hasPrefix(bareAPIHandleShareLinkPrefix) {
            rawPublicID = "@\(String(normalized.dropFirst(bareAPIHandleShareLinkPrefix.count)))"
        } else if normalized.hasPrefix(bareHandleShareLinkPrefix) {
            rawPublicID = "@\(String(normalized.dropFirst(bareHandleShareLinkPrefix.count)))"
        } else if normalized.hasPrefix(apiRootShareLinkPrefix) {
            rawPublicID = String(normalized.dropFirst(apiRootShareLinkPrefix.count))
        } else if normalized.hasPrefix(rootShareLinkPrefix) {
            rawPublicID = String(normalized.dropFirst(rootShareLinkPrefix.count))
        } else if normalized.hasPrefix(bareAPIRootShareLinkPrefix) {
            rawPublicID = String(normalized.dropFirst(bareAPIRootShareLinkPrefix.count))
        } else if normalized.hasPrefix(bareRootShareLinkPrefix) {
            rawPublicID = String(normalized.dropFirst(bareRootShareLinkPrefix.count))
        } else if normalized.hasPrefix(apiLegacyShareLinkPrefix) {
            rawPublicID = String(normalized.dropFirst(apiLegacyShareLinkPrefix.count))
        } else if normalized.hasPrefix(legacyShareLinkPrefix) {
            rawPublicID = String(normalized.dropFirst(legacyShareLinkPrefix.count))
        } else if normalized.hasPrefix(apiLegacyBareShareLinkPrefix) {
            rawPublicID = String(normalized.dropFirst(apiLegacyBareShareLinkPrefix.count))
        } else if normalized.hasPrefix(legacyBareShareLinkPrefix) {
            rawPublicID = String(normalized.dropFirst(legacyBareShareLinkPrefix.count))
        } else {
            rawPublicID = normalized
        }

        let publicID = rawPublicID.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? rawPublicID
        return publicID
    }
}
