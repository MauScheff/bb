import Foundation

/// Client-only UX shortcuts layered on top of the underlying handshake state machine.
/// Keep these switches explicit and persisted so they can be disabled during debugging
/// without changing backend truth or reducer semantics.
struct ConversationShortcutPolicy: Equatable {
    static let senderAutoJoinOnBeepAcceptanceStorageKey =
        "turbo.shortcuts.senderAutoJoinOnBeepAcceptance"

    var senderAutoJoinOnBeepAcceptance: Bool = true

    static func load(from defaults: UserDefaults = .standard) -> ConversationShortcutPolicy {
        guard defaults.object(forKey: senderAutoJoinOnBeepAcceptanceStorageKey) != nil else {
            return ConversationShortcutPolicy()
        }

        return ConversationShortcutPolicy(
            senderAutoJoinOnBeepAcceptance: defaults.bool(
                forKey: senderAutoJoinOnBeepAcceptanceStorageKey
            )
        )
    }

    static func store(_ policy: ConversationShortcutPolicy, to defaults: UserDefaults = .standard) {
        defaults.set(
            policy.senderAutoJoinOnBeepAcceptance,
            forKey: senderAutoJoinOnBeepAcceptanceStorageKey
        )
    }
}
