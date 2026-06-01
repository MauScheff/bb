import Foundation

nonisolated enum TurboHandle {
    static let minBodyLength = 3
    static let maxBodyLength = 20
    static let reservedURLBodies: Set<String> = [
        ".well-known",
        "apple-app-site-association",
        "health",
        "id",
        "p",
        "v1",
    ]

    static func normalizedStoredHandle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "@beepbeep" }
        if trimmed.hasPrefix("@") {
            return trimmed
        }
        return "@\(trimmed)"
    }

    static func body(from raw: String) -> String {
        let canonical = normalizedStoredHandle(raw)
        return canonical.hasPrefix("@") ? String(canonical.dropFirst()) : canonical
    }

    static func normalizedEditableBody(_ raw: String) -> String {
        let filtered = body(from: raw).filter { $0.isLetter || $0.isNumber }
        return String(filtered.prefix(maxBodyLength))
    }

    static func isValidEditableBody(_ raw: String) -> Bool {
        let normalized = normalizedEditableBody(raw)
        guard normalized == raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized.count >= minBodyLength && normalized.count <= maxBodyLength
    }

    static func canonicalHandle(fromEditableBody raw: String) -> String {
        "@\(normalizedEditableBody(raw))"
    }

    static func sharePathComponent(from raw: String) -> String {
        body(from: raw)
    }

    static func isReservedURLBody(_ raw: String) -> Bool {
        reservedURLBodies.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func suggestedEditableBody(from profileName: String) -> String {
        let direct = normalizedEditableBody(profileName)
        if direct.count >= minBodyLength {
            return direct
        }

        let fallback = normalizedEditableBody(TurboSuggestedProfileName.generate())
        if fallback.count >= minBodyLength {
            return fallback
        }

        return "beepbeep"
    }
}
