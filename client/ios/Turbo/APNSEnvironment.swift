import Foundation

enum TurboAPNSEnvironment: String, Encodable {
    case development
    case production

    var isSandbox: Bool {
        self == .development
    }
}

enum TurboAPNSEnvironmentResolver {
    static func current(bundle: Bundle = .main) -> TurboAPNSEnvironment {
        let infoPlistValue = bundle.object(forInfoDictionaryKey: "APNSEnvironment") as? String
#if DEBUG
        return resolve(infoPlistValue: infoPlistValue, fallback: .development)
#else
        return resolve(infoPlistValue: infoPlistValue, fallback: .production)
#endif
    }

    static func resolve(
        infoPlistValue: String?,
        fallback: TurboAPNSEnvironment
    ) -> TurboAPNSEnvironment {
        guard let infoPlistValue,
              let environment = TurboAPNSEnvironment(rawValue: infoPlistValue) else {
            return fallback
        }
        return environment
    }
}
