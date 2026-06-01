import Foundation

struct PTTTokenUploadRequest: Equatable {
    let backendChannelID: String
    let tokenHex: String
}

struct PTTSystemPolicyPersistence {
    private static let latestTokenHexKey = "turbo.pttSystemPolicy.latestTokenHex"
    private static let uploadedTokenHexKey = "turbo.pttSystemPolicy.uploadedTokenHex"
    private static let uploadedBackendChannelIDKey = "turbo.pttSystemPolicy.uploadedBackendChannelID"
    private static let lastTokenUploadErrorKey = "turbo.pttSystemPolicy.lastTokenUploadError"

    static func load(from defaults: UserDefaults) -> PTTSystemPolicyState {
        PTTSystemPolicyState(
            latestTokenHex: defaults.string(forKey: latestTokenHexKey) ?? "",
            lastTokenUploadError: defaults.string(forKey: lastTokenUploadErrorKey),
            uploadedTokenHex: defaults.string(forKey: uploadedTokenHexKey),
            uploadedBackendChannelID: defaults.string(forKey: uploadedBackendChannelIDKey)
        )
    }

    static func store(_ state: PTTSystemPolicyState, to defaults: UserDefaults) {
        if let latestTokenHex = state.tokenRegistration.latestTokenHex,
           !latestTokenHex.isEmpty {
            defaults.set(latestTokenHex, forKey: latestTokenHexKey)
        } else {
            defaults.removeObject(forKey: latestTokenHexKey)
        }

        if let uploadedTokenHex = state.uploadedTokenHex {
            defaults.set(uploadedTokenHex, forKey: uploadedTokenHexKey)
        } else {
            defaults.removeObject(forKey: uploadedTokenHexKey)
        }

        if let uploadedBackendChannelID = state.uploadedBackendChannelID {
            defaults.set(uploadedBackendChannelID, forKey: uploadedBackendChannelIDKey)
        } else {
            defaults.removeObject(forKey: uploadedBackendChannelIDKey)
        }

        if let lastTokenUploadError = state.lastTokenUploadError {
            defaults.set(lastTokenUploadError, forKey: lastTokenUploadErrorKey)
        } else {
            defaults.removeObject(forKey: lastTokenUploadErrorKey)
        }
    }
}

enum PTTTokenRegistrationState: Equatable {
    case idle
    case tokenKnown(tokenHex: String, backendChannelID: String?)
    case uploadPending(PTTTokenUploadRequest)
    case registered(PTTTokenUploadRequest)
    case uploadFailed(
        latestTokenHex: String,
        backendChannelID: String?,
        attemptedRequest: PTTTokenUploadRequest?,
        message: String
    )

    var latestTokenHex: String? {
        switch self {
        case .idle:
            return nil
        case .tokenKnown(let tokenHex, _):
            return tokenHex
        case .uploadPending(let request), .registered(let request):
            return request.tokenHex
        case .uploadFailed(let latestTokenHex, _, _, _):
            return latestTokenHex
        }
    }

    var backendChannelID: String? {
        switch self {
        case .idle:
            return nil
        case .tokenKnown(_, let backendChannelID):
            return backendChannelID
        case .uploadPending(let request), .registered(let request):
            return request.backendChannelID
        case .uploadFailed(_, let backendChannelID, _, _):
            return backendChannelID
        }
    }

    var uploadedRequest: PTTTokenUploadRequest? {
        guard case .registered(let request) = self else { return nil }
        return request
    }

    var pendingRequest: PTTTokenUploadRequest? {
        guard case .uploadPending(let request) = self else { return nil }
        return request
    }

    var attemptedRequest: PTTTokenUploadRequest? {
        switch self {
        case .uploadPending(let request), .registered(let request):
            return request
        case .uploadFailed(_, _, let attemptedRequest, _):
            return attemptedRequest
        case .idle, .tokenKnown:
            return nil
        }
    }

    var lastErrorMessage: String? {
        guard case .uploadFailed(_, _, _, let message) = self else { return nil }
        return message
    }

    var diagnosticsDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .tokenKnown(_, let backendChannelID):
            return "token-known(channel: \(backendChannelID ?? "none"))"
        case .uploadPending(let request):
            return "upload-pending(channel: \(request.backendChannelID))"
        case .registered(let request):
            return "registered(channel: \(request.backendChannelID))"
        case .uploadFailed(_, let backendChannelID, _, _):
            return "upload-failed(channel: \(backendChannelID ?? "none"))"
        }
    }

    var kindDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .tokenKnown:
            return "token-known"
        case .uploadPending:
            return "upload-pending"
        case .registered:
            return "registered"
        case .uploadFailed:
            return "upload-failed"
        }
    }
}

struct PTTSystemPolicyState: Equatable {
    var tokenRegistration: PTTTokenRegistrationState = .idle

    init(
        tokenRegistration: PTTTokenRegistrationState = .idle
    ) {
        self.tokenRegistration = tokenRegistration
    }

    init(
        latestTokenHex: String = "",
        lastTokenUploadError: String? = nil,
        uploadedTokenHex: String? = nil,
        uploadedBackendChannelID: String? = nil
    ) {
        if let uploadedTokenHex,
           let uploadedBackendChannelID {
            let request = PTTTokenUploadRequest(
                backendChannelID: uploadedBackendChannelID,
                tokenHex: uploadedTokenHex
            )
            if let lastTokenUploadError {
                tokenRegistration = .uploadFailed(
                    latestTokenHex: latestTokenHex.isEmpty ? uploadedTokenHex : latestTokenHex,
                    backendChannelID: uploadedBackendChannelID,
                    attemptedRequest: request,
                    message: lastTokenUploadError
                )
            } else {
                tokenRegistration = .registered(request)
            }
            return
        }

        guard !latestTokenHex.isEmpty else {
            tokenRegistration = .idle
            return
        }

        if let lastTokenUploadError {
            tokenRegistration = .uploadFailed(
                latestTokenHex: latestTokenHex,
                backendChannelID: uploadedBackendChannelID,
                attemptedRequest: uploadedBackendChannelID.map {
                    PTTTokenUploadRequest(
                        backendChannelID: $0,
                        tokenHex: latestTokenHex
                    )
                },
                message: lastTokenUploadError
            )
        } else {
            tokenRegistration = .tokenKnown(
                tokenHex: latestTokenHex,
                backendChannelID: uploadedBackendChannelID
            )
        }
    }

    var latestTokenHex: String {
        tokenRegistration.latestTokenHex ?? ""
    }

    var lastTokenUploadError: String? {
        tokenRegistration.lastErrorMessage
    }

    var uploadedTokenHex: String? {
        tokenRegistration.uploadedRequest?.tokenHex
    }

    var uploadedBackendChannelID: String? {
        tokenRegistration.uploadedRequest?.backendChannelID
    }

    var tokenRegistrationDescription: String {
        tokenRegistration.diagnosticsDescription
    }

    var tokenRegistrationKind: String {
        tokenRegistration.kindDescription
    }

    static let initial = PTTSystemPolicyState()
}

enum PTTSystemPolicyEvent: Equatable {
    case ephemeralTokenReceived(tokenHex: String, backendChannelID: String?)
    case backendChannelReady(String)
    case tokenUploadFinished(PTTTokenUploadRequest)
    case tokenUploadFailed(String)
    case reset
}

enum PTTSystemPolicyEffect: Equatable {
    case uploadEphemeralToken(PTTTokenUploadRequest)
}

struct PTTSystemPolicyTransition: Equatable {
    var state: PTTSystemPolicyState
    var effects: [PTTSystemPolicyEffect] = []
}

enum PTTSystemPolicyReducer {
    static func reduce(
        state: PTTSystemPolicyState,
        event: PTTSystemPolicyEvent
    ) -> PTTSystemPolicyTransition {
        var nextState = state
        var effects: [PTTSystemPolicyEffect] = []

        switch event {
        case .ephemeralTokenReceived(let tokenHex, let backendChannelID):
            nextState.tokenRegistration = .tokenKnown(
                tokenHex: tokenHex,
                backendChannelID: backendChannelID
            )
            if let request = uploadRequestIfNeeded(
                latestTokenHex: tokenHex,
                backendChannelID: backendChannelID,
                tokenRegistration: state.tokenRegistration
            ) {
                nextState.tokenRegistration = .uploadPending(request)
                effects.append(.uploadEphemeralToken(request))
            }

        case .backendChannelReady(let backendChannelID):
            if let latestTokenHex = state.tokenRegistration.latestTokenHex {
                let request = PTTTokenUploadRequest(
                    backendChannelID: backendChannelID,
                    tokenHex: latestTokenHex
                )
                switch state.tokenRegistration {
                case .uploadPending(let pendingRequest) where pendingRequest == request:
                    nextState.tokenRegistration = state.tokenRegistration
                case .registered(let registeredRequest) where registeredRequest == request:
                    nextState.tokenRegistration = state.tokenRegistration
                default:
                    nextState.tokenRegistration = .tokenKnown(
                        tokenHex: latestTokenHex,
                        backendChannelID: backendChannelID
                    )
                    nextState.tokenRegistration = .uploadPending(request)
                    effects.append(.uploadEphemeralToken(request))
                }
            }

        case .tokenUploadFinished(let request):
            nextState.tokenRegistration = .registered(request)

        case .tokenUploadFailed(let message):
            nextState.tokenRegistration = .uploadFailed(
                latestTokenHex: state.tokenRegistration.latestTokenHex ?? "",
                backendChannelID: state.tokenRegistration.backendChannelID,
                attemptedRequest: state.tokenRegistration.attemptedRequest,
                message: message
            )

        case .reset:
            if let latestTokenHex = state.tokenRegistration.latestTokenHex,
               !latestTokenHex.isEmpty {
                // The Apple ephemeral token is device-scoped and may not be
                // re-delivered after every local reset, so preserve it while
                // clearing any stale backend-channel binding.
                nextState = PTTSystemPolicyState(latestTokenHex: latestTokenHex)
            } else {
                nextState = .initial
            }
        }

        return PTTSystemPolicyTransition(state: nextState, effects: effects)
    }

    private static func uploadRequestIfNeeded(
        latestTokenHex: String,
        backendChannelID: String?,
        tokenRegistration: PTTTokenRegistrationState
    ) -> PTTTokenUploadRequest? {
        guard let backendChannelID else { return nil }
        let request = PTTTokenUploadRequest(
            backendChannelID: backendChannelID,
            tokenHex: latestTokenHex
        )
        switch tokenRegistration {
        case .uploadPending(let pendingRequest) where pendingRequest == request:
            return nil
        case .registered(let registeredRequest) where registeredRequest == request:
            return nil
        default:
            break
        }
        return request
    }
}

@MainActor
final class PTTSystemPolicyCoordinator {
    private(set) var state = PTTSystemPolicyState.initial
    var effectHandler: (@MainActor (PTTSystemPolicyEffect) async -> Void)?
    var stateChangeHandler: ((PTTSystemPolicyState) -> Void)?

    func replaceState(_ newState: PTTSystemPolicyState) {
        state = newState
        stateChangeHandler?(state)
    }

    func send(_ event: PTTSystemPolicyEvent) {
        state = PTTSystemPolicyReducer.reduce(state: state, event: event).state
        stateChangeHandler?(state)
    }

    func handle(_ event: PTTSystemPolicyEvent) async {
        let transition = PTTSystemPolicyReducer.reduce(state: state, event: event)
        state = transition.state
        stateChangeHandler?(state)
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }
}

enum PTTSystemDisplayPolicy {
    static func pushTokenHex(from token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    static func restoredDescriptorName(
        channelUUID: UUID,
        contacts: [Contact],
        fallbackName: String
    ) -> String {
        if let contact = contacts.first(where: { $0.channelId == channelUUID }) {
            return "Chat with \(contact.name)"
        }
        return fallbackName
    }
}
