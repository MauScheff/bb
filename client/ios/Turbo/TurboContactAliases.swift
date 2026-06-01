import Foundation

enum TurboContactAliasStore {
    private static let aliasesKey = "TurboContactAliasesByOwner"

    static func localName(for contactID: UUID, ownerKey: String) -> String? {
        aliases(for: ownerKey)[contactID.uuidString]
    }

    static func storeLocalName(_ localName: String?, for contactID: UUID, ownerKey: String) -> String? {
        let normalized = Contact.normalizedLocalName(localName)
        var aliasesByOwner = UserDefaults.standard.dictionary(forKey: aliasesKey) as? [String: [String: String]] ?? [:]
        var aliases = aliasesByOwner[ownerKey] ?? [:]
        if let normalized {
            aliases[contactID.uuidString] = normalized
        } else {
            aliases.removeValue(forKey: contactID.uuidString)
        }
        aliasesByOwner[ownerKey] = aliases
        UserDefaults.standard.set(aliasesByOwner, forKey: aliasesKey)
        return normalized
    }

    private static func aliases(for ownerKey: String) -> [String: String] {
        let aliasesByOwner = UserDefaults.standard.dictionary(forKey: aliasesKey) as? [String: [String: String]] ?? [:]
        return aliasesByOwner[ownerKey] ?? [:]
    }
}
