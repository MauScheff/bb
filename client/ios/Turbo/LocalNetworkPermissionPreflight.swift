import Foundation
import Network

enum LocalNetworkPreflightStatus: Equatable {
    case notRun
    case running
    case completed(Date)
    case failed(String)

    private static let enabledAtStorageKey = "turbo.localNetworkPermissionEnabledAt"

    static func loadStored(defaults: UserDefaults = .standard) -> LocalNetworkPreflightStatus {
        guard let enabledAt = defaults.object(forKey: enabledAtStorageKey) as? Date else {
            return .notRun
        }
        return .completed(enabledAt)
    }

    static func storeEnabled(at enabledAt: Date, defaults: UserDefaults = .standard) {
        defaults.set(enabledAt, forKey: enabledAtStorageKey)
    }

    static func clearStoredEnabled(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledAtStorageKey)
    }

    var displayText: String {
        switch self {
        case .notRun:
            return "Local network not checked"
        case .running:
            return "Checking local network..."
        case .completed:
            return "Local network enabled"
        case .failed:
            return "Local network check failed"
        }
    }

    var detailText: String {
        switch self {
        case .notRun:
            return "not checked"
        case .running:
            return "checking"
        case .completed(let completedAt):
            return "checked at \(completedAt.formatted(date: .omitted, time: .standard))"
        case .failed(let reason):
            return "failed: \(reason)"
        }
    }

    var shouldShowMainSurfaceControl: Bool {
        switch self {
        case .completed:
            return false
        case .notRun, .running, .failed:
            return true
        }
    }
}

@MainActor
final class LocalNetworkPermissionPreflight {
    private let serviceType = "_turbo-preflight._tcp"
    private var browser: NWBrowser?

    func run(
        diagnostics: DiagnosticsStore,
        stateDidChange: @MainActor @escaping (LocalNetworkPreflightStatus) -> Void
    ) async {
        browser?.cancel()
        stateDidChange(.running)
        diagnostics.record(
            .app,
            message: "Local network permission preflight started",
            metadata: ["serviceType": serviceType]
        )

        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                diagnostics.record(
                    .app,
                    message: "Local network permission preflight state changed",
                    metadata: ["state": self.description(for: state)]
                )

                switch state {
                case .failed(let error):
                    if self.browser === browser {
                        self.browser = nil
                    }
                    browser.cancel()
                    LocalNetworkPreflightStatus.clearStoredEnabled()
                    stateDidChange(.failed(error.localizedDescription))
                case .cancelled:
                    if self.browser === browser {
                        self.browser = nil
                    }
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard self.browser === browser else { return }
        browser.cancel()
        self.browser = nil
        let completedAt = Date()
        LocalNetworkPreflightStatus.storeEnabled(at: completedAt)
        stateDidChange(.completed(completedAt))
        diagnostics.record(
            .app,
            message: "Local network permission preflight completed",
            metadata: ["serviceType": serviceType]
        )
    }

    private func description(for state: NWBrowser.State) -> String {
        switch state {
        case .setup:
            return "setup"
        case .ready:
            return "ready"
        case .failed(let error):
            return "failed:\(error.localizedDescription)"
        case .cancelled:
            return "cancelled"
        case .waiting(let error):
            return "waiting:\(error.localizedDescription)"
        @unknown default:
            return "unknown"
        }
    }
}
