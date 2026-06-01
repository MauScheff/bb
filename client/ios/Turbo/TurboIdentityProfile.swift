import Foundation

enum TurboIdentityProfileStore {
    private static let draftProfileNameKey = "TurboIdentityProfileName"
    private static let completedOnboardingKey = "TurboIdentityOnboardingCompleted"

    static func draftProfileName() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: draftProfileNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        let generated = TurboSuggestedProfileName.generate()
        defaults.set(generated, forKey: draftProfileNameKey)
        return generated
    }

    static func storeDraftProfileName(_ profileName: String) -> String {
        let normalized = normalizedProfileName(profileName)
        UserDefaults.standard.set(normalized, forKey: draftProfileNameKey)
        return normalized
    }

    static func hasCompletedOnboarding() -> Bool {
        UserDefaults.standard.bool(forKey: completedOnboardingKey)
    }

    static func markOnboardingCompleted() {
        UserDefaults.standard.set(true, forKey: completedOnboardingKey)
    }

    static func resetOnboarding() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: draftProfileNameKey)
        defaults.set(false, forKey: completedOnboardingKey)
    }

    static func resetForFreshIdentity() {
        resetOnboarding()
        TurboBackendConfig.resetPersistedIdentity()
    }

    static func normalizedProfileName(_ profileName: String) -> String {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return draftProfileName() }
        return trimmed
    }
}

nonisolated enum TurboSuggestedProfileName {
    private static let adjectives = [
        "Amber", "Breezy", "Cinder", "Clever", "Cloudy", "Comet", "Copper", "Cozy",
        "Daring", "Drift", "Echo", "Feather", "Fizzy", "Golden", "Harbor", "Jolly",
        "Lively", "Lucky", "Mellow", "Mint", "Pebble", "Pepper", "Pocket", "Rocket",
        "Saffron", "Shiny", "Sunny", "Velvet", "Wavy", "Zippy"
    ]

    private static let nouns = [
        "Badger", "Biscuit", "Bloom", "Comet", "Falcon", "Fern", "Firefly", "Harbor",
        "Lemon", "Meadow", "Meteor", "Otter", "Pebble", "Pine", "Ripple", "Robin",
        "Rocket", "Sparrow", "Sprout", "Starling", "Summit", "Thistle", "Tiger", "Willow"
    ]

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    static func generate<T: RandomNumberGenerator>(using generator: inout T) -> String {
        let adjective = adjectives.randomElement(using: &generator) ?? "Sunny"
        let noun = nouns.randomElement(using: &generator) ?? "Otter"
        return "\(adjective) \(noun)"
    }
}
