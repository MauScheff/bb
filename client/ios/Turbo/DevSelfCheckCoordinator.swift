import Foundation
import AVFAudio

struct DevSelfCheckTarget: Equatable {
    let contactID: UUID
    let handle: String
}

struct DevSelfCheckRequest: Equatable {
    let startedAt: Date
    let hasBackendConfig: Bool
    let isBackendClientReady: Bool
    let microphonePermission: AVAudioApplication.recordPermission
    let selectedTarget: DevSelfCheckTarget?
}

struct DevSelfCheckContactUpdate: Equatable {
    let contactID: UUID
    let remoteUserID: String
    let backendChannelID: String
    let channelUUID: UUID
}

struct DevSelfCheckChannelStateUpdate: Equatable {
    let contactID: UUID
    let channelState: TurboChannelStateResponse
}

struct DevSelfCheckOutcome: Equatable {
    let report: DevSelfCheckReport
    let authenticatedUserID: String?
    let contactUpdate: DevSelfCheckContactUpdate?
    let channelStateUpdate: DevSelfCheckChannelStateUpdate?
}

struct DevSelfCheckSessionState: Equatable {
    var latestReport: DevSelfCheckReport?
    var isRunning: Bool = false

    static let initial = DevSelfCheckSessionState()
}

enum DevSelfCheckEvent: Equatable {
    case runRequested(DevSelfCheckRequest)
    case runCompleted(DevSelfCheckReport)
    case reset
}

enum DevSelfCheckEffect: Equatable {
    case run(DevSelfCheckRequest)
}

struct DevSelfCheckTransition: Equatable {
    var state: DevSelfCheckSessionState
    var effects: [DevSelfCheckEffect] = []
}

enum DevSelfCheckReducer {
    static func reduce(
        state: DevSelfCheckSessionState,
        event: DevSelfCheckEvent
    ) -> DevSelfCheckTransition {
        var nextState = state
        var effects: [DevSelfCheckEffect] = []

        switch event {
        case .runRequested(let request):
            guard !nextState.isRunning else {
                return DevSelfCheckTransition(state: nextState)
            }
            nextState.isRunning = true
            effects.append(.run(request))

        case .runCompleted(let report):
            nextState.isRunning = false
            nextState.latestReport = report

        case .reset:
            nextState = .initial
        }

        return DevSelfCheckTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class DevSelfCheckCoordinator {
    private(set) var state = DevSelfCheckSessionState.initial
    var effectHandler: (@MainActor (DevSelfCheckEffect) async -> Void)?

    func send(_ event: DevSelfCheckEvent) {
        state = DevSelfCheckReducer.reduce(state: state, event: event).state
    }

    func handle(_ event: DevSelfCheckEvent) async {
        let transition = DevSelfCheckReducer.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }
}

struct DevSelfCheckServices {
    let fetchRuntimeConfig: () async throws -> TurboBackendRuntimeConfig
    let authenticate: () async throws -> TurboAuthSessionResponse
    let heartbeatPresence: () async throws -> TurboPresenceHeartbeatResponse
    let ensureWebSocketConnected: () -> Void
    let waitForWebSocketConnection: () async throws -> Void
    let lookupUser: (_ handle: String) async throws -> TurboUserLookupResponse
    let directChannel: (_ handle: String) async throws -> TurboDirectChannelResponse
    let channelState: (_ channelID: String) async throws -> TurboChannelStateResponse
    let alignmentAction: (_ contactUpdate: DevSelfCheckContactUpdate) -> SelectedConversationReconciliationAction
}

enum DevSelfCheckRunner {
    @MainActor
    static func run(
        request: DevSelfCheckRequest,
        services: DevSelfCheckServices
    ) async -> DevSelfCheckOutcome {
        var steps: [DevSelfCheckStep] = []
        let targetHandle = request.selectedTarget?.handle

        guard request.hasBackendConfig else {
            let step = DevSelfCheckStep(.backendConfig, status: .failed, detail: "Backend configuration is missing")
            steps.append(step)
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: targetHandle,
                    steps: steps
                ),
                authenticatedUserID: nil,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        }
        steps.append(DevSelfCheckStep(.backendConfig, status: .passed, detail: "Backend config loaded"))

        switch request.microphonePermission {
        case .granted:
            steps.append(DevSelfCheckStep(.microphonePermission, status: .passed, detail: "Microphone access granted"))
        case .denied:
            steps.append(DevSelfCheckStep(.microphonePermission, status: .failed, detail: "Microphone access denied"))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: targetHandle,
                    steps: steps
                ),
                authenticatedUserID: nil,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        case .undetermined:
            steps.append(DevSelfCheckStep(.microphonePermission, status: .failed, detail: "Microphone access has not been requested"))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: targetHandle,
                    steps: steps
                ),
                authenticatedUserID: nil,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        @unknown default:
            steps.append(DevSelfCheckStep(.microphonePermission, status: .failed, detail: "Unknown microphone permission state"))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: targetHandle,
                    steps: steps
                ),
                authenticatedUserID: nil,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        }

        guard request.isBackendClientReady else {
            steps.append(DevSelfCheckStep(.runtimeConfig, status: .failed, detail: "Backend client is not initialized"))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: targetHandle,
                    steps: steps
                ),
                authenticatedUserID: nil,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        }

        let runtimeConfig: TurboBackendRuntimeConfig
        do {
            runtimeConfig = try await services.fetchRuntimeConfig()
            let relayOnlyOverride = TurboDirectPathDebugOverride.isRelayOnlyForced()
            steps.append(
                DevSelfCheckStep(
                    .runtimeConfig,
                    status: .passed,
                    detail: "Mode \(runtimeConfig.mode), websocket \(runtimeConfig.supportsWebSocket ? "on" : "off"), direct-quic \(runtimeConfig.supportsDirectQuicUpgrade ? "on" : "off"), relay-only override \(relayOnlyOverride ? "on" : "off")"
                )
            )
        } catch {
            steps.append(DevSelfCheckStep(.runtimeConfig, status: .failed, detail: error.localizedDescription))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: targetHandle,
                    steps: steps
                ),
                authenticatedUserID: nil,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        }

        let session: TurboAuthSessionResponse
        do {
            session = try await services.authenticate()
            steps.append(DevSelfCheckStep(.authSession, status: .passed, detail: "Authenticated as \(session.handle)"))
        } catch {
            steps.append(DevSelfCheckStep(.authSession, status: .failed, detail: error.localizedDescription))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: targetHandle,
                    steps: steps
                ),
                authenticatedUserID: nil,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        }

        do {
            _ = try await services.heartbeatPresence()
            steps.append(DevSelfCheckStep(.deviceHeartbeat, status: .passed, detail: "Presence heartbeat succeeded"))
        } catch {
            steps.append(DevSelfCheckStep(.deviceHeartbeat, status: .failed, detail: error.localizedDescription))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: targetHandle,
                    steps: steps
                ),
                authenticatedUserID: session.userId,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        }

        if runtimeConfig.supportsWebSocket {
            do {
                services.ensureWebSocketConnected()
                try await services.waitForWebSocketConnection()
                steps.append(DevSelfCheckStep(.websocket, status: .passed, detail: "WebSocket connected"))
            } catch {
                steps.append(DevSelfCheckStep(.websocket, status: .failed, detail: error.localizedDescription))
                return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: targetHandle,
                    steps: steps
                ),
                    authenticatedUserID: session.userId,
                    contactUpdate: nil,
                    channelStateUpdate: nil
                )
            }
        } else {
            steps.append(DevSelfCheckStep(.websocket, status: .skipped, detail: "Runtime does not use websockets"))
        }

        guard let target = request.selectedTarget else {
            steps.append(DevSelfCheckStep(.friendLookup, status: .skipped, detail: "No selected Friend"))
            steps.append(DevSelfCheckStep(.directChannel, status: .skipped, detail: "No selected Friend"))
            steps.append(DevSelfCheckStep(.channelState, status: .skipped, detail: "No selected Friend"))
            steps.append(DevSelfCheckStep(.sessionAlignment, status: .skipped, detail: "Select a Friend to check Device PTT alignment"))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: nil,
                    steps: steps
                ),
                authenticatedUserID: session.userId,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        }

        let resolvedUser: TurboUserLookupResponse
        do {
            resolvedUser = try await services.lookupUser(target.handle)
            steps.append(DevSelfCheckStep(.friendLookup, status: .passed, detail: "Resolved \(resolvedUser.handle)"))
        } catch {
            steps.append(DevSelfCheckStep(.friendLookup, status: .failed, detail: error.localizedDescription))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: target.handle,
                    steps: steps
                ),
                authenticatedUserID: session.userId,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        }

        let directChannel: TurboDirectChannelResponse
        do {
            directChannel = try await services.directChannel(target.handle)
            steps.append(DevSelfCheckStep(.directChannel, status: .passed, detail: "Channel \(directChannel.channelId)"))
        } catch {
            steps.append(DevSelfCheckStep(.directChannel, status: .failed, detail: error.localizedDescription))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: target.handle,
                    steps: steps
                ),
                authenticatedUserID: session.userId,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
        }

        let contactUpdate = DevSelfCheckContactUpdate(
            contactID: target.contactID,
            remoteUserID: resolvedUser.userId,
            backendChannelID: directChannel.channelId,
            channelUUID: ContactDirectory.stableChannelUUID(for: directChannel.channelId)
        )

        let channelState: TurboChannelStateResponse
        do {
            channelState = try await services.channelState(directChannel.channelId)
            steps.append(
                DevSelfCheckStep(
                    .channelState,
                    status: .passed,
                    detail: "selfJoined=\(channelState.selfJoined) peerJoined=\(channelState.peerJoined) peerConnected=\(channelState.peerDeviceConnected) status=\(channelState.status)"
                )
            )
        } catch {
            steps.append(DevSelfCheckStep(.channelState, status: .failed, detail: error.localizedDescription))
            return DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: target.handle,
                    steps: steps
                ),
                authenticatedUserID: session.userId,
                contactUpdate: contactUpdate,
                channelStateUpdate: nil
            )
        }

        switch services.alignmentAction(contactUpdate) {
        case .none:
            steps.append(DevSelfCheckStep(.sessionAlignment, status: .passed, detail: "Local Device PTT and backend Conversation state agree"))
        case .restoreDevicePTTSession:
            steps.append(DevSelfCheckStep(.sessionAlignment, status: .failed, detail: "Backend is ready but local Device PTT must be restored"))
        case .teardownDevicePTTSession:
            steps.append(DevSelfCheckStep(.sessionAlignment, status: .failed, detail: "Local Device PTT is stale and must be torn down"))
        case .clearStaleBackendMembership:
            steps.append(DevSelfCheckStep(.sessionAlignment, status: .failed, detail: "Backend membership is stale and must be cleared"))
        }

        return DevSelfCheckOutcome(
            report: DevSelfCheckReport(
                startedAt: request.startedAt,
                completedAt: Date(),
                targetHandle: target.handle,
                steps: steps
            ),
            authenticatedUserID: session.userId,
            contactUpdate: contactUpdate,
            channelStateUpdate: DevSelfCheckChannelStateUpdate(contactID: target.contactID, channelState: channelState)
        )
    }
}
