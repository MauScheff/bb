import Foundation

enum TurboContactAliasStore {
    private static let aliasesKey = "TurboContactAliasesByOwner"

    static func localName(
        for contactID: UUID,
        ownerKey: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        aliases(for: ownerKey, defaults: defaults)[contactID.uuidString]
    }

    static func storeLocalName(
        _ localName: String?,
        for contactID: UUID,
        ownerKey: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        let normalized = Contact.normalizedLocalName(localName)
        var aliasesByOwner = aliasesByOwner(defaults: defaults)
        var aliases = aliasesByOwner[ownerKey] ?? [:]
        if let normalized {
            aliases[contactID.uuidString] = normalized
        } else {
            aliases.removeValue(forKey: contactID.uuidString)
        }
        aliasesByOwner[ownerKey] = aliases
        defaults.set(aliasesByOwner, forKey: aliasesKey)
        return normalized
    }

    private static func aliases(for ownerKey: String, defaults: UserDefaults) -> [String: String] {
        aliasesByOwner(defaults: defaults)[ownerKey] ?? [:]
    }

    private static func aliasesByOwner(defaults: UserDefaults) -> [String: [String: String]] {
        guard let raw = defaults.object(forKey: aliasesKey) as? [String: Any] else {
            return [:]
        }

        var result: [String: [String: String]] = [:]
        for (ownerKey, ownerAliases) in raw {
            guard let aliasMap = ownerAliases as? [String: String] else {
                continue
            }
            result[ownerKey] = aliasMap
        }
        return result
    }
}
