import Foundation
import Testing
import PushToTalk
import AVFAudio
import UIKit
import UserNotifications
import Intents
import CryptoKit
import TurboEngine

@testable import BeepBeep

struct ScenarioFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

struct SimulatorScenarioConfig: Decodable {
    let name: String
    let baseURL: URL
    let requiresLocalBackend: Bool?
    let participants: [String: SimulatorScenarioParticipant]
    let steps: [SimulatorScenarioStep]
}

struct SimulatorScenarioParticipant: Decodable {
    let handle: String
    let deviceId: String
}

struct SimulatorScenarioStep: Decodable {
    let description: String
    let actions: [SimulatorScenarioAction]
    let expectEventually: [String: SimulatorScenarioExpectation]?
}

struct SimulatorScenarioAction: Decodable {
    let actor: String
    let type: String
    let friend: String?
    let route: String?
    let signalKind: String?
    let pathState: String?
    let networkInterface: String?
    let reason: String?
    let milliseconds: Int?
    let count: Int?
    let delayMilliseconds: Int?
    let repeatCount: Int?
    let repeatIntervalMilliseconds: Int?
    let reorderIndex: Int?
    let drop: Bool?

    init(
        actor: String,
        type: String,
        friend: String? = nil,
        route: String? = nil,
        signalKind: String? = nil,
        pathState: String? = nil,
        networkInterface: String? = nil,
        reason: String? = nil,
        milliseconds: Int? = nil,
        count: Int? = nil,
        delayMilliseconds: Int? = nil,
        repeatCount: Int? = nil,
        repeatIntervalMilliseconds: Int? = nil,
        reorderIndex: Int? = nil,
        drop: Bool? = nil
    ) {
        self.actor = actor
        self.type = type
        self.friend = friend
        self.route = route
        self.signalKind = signalKind
        self.pathState = pathState
        self.networkInterface = networkInterface
        self.reason = reason
        self.milliseconds = milliseconds
        self.count = count
        self.delayMilliseconds = delayMilliseconds
        self.repeatCount = repeatCount
        self.repeatIntervalMilliseconds = repeatIntervalMilliseconds
        self.reorderIndex = reorderIndex
        self.drop = drop
    }
}

struct SimulatorScenarioExpectation: Decodable {
    let selectedHandle: String?
    let phase: String?
    let selectedStatus: String?
    let isJoined: Bool?
    let isTransmitting: Bool?
    let canTransmitNow: Bool?
    let pttTokenRegistrationKind: String?
    let transportPathState: String?
    let localNetworkInterface: String?
    let selected: SimulatorScenarioSelectedExpectation?
    let contacts: [SimulatorScenarioContactExpectation]?
    let backend: SimulatorScenarioBackendExpectation?
    let noInvariantViolations: Bool?
    let expectInvariant: [String]?
    let eventuallyNoInvariant: [String]?
    let allowInvariantDuringStep: [String]?
    let diagnosticsContains: [String]?
    let diagnosticsNotContains: [String]?

    var selectedExpectation: SimulatorScenarioSelectedExpectation? {
        if let selected {
            return selected
        }

        if selectedHandle != nil
            || phase != nil
            || selectedStatus != nil
            || isJoined != nil
            || isTransmitting != nil
            || canTransmitNow != nil
            || pttTokenRegistrationKind != nil
        {
            return SimulatorScenarioSelectedExpectation(
                handle: selectedHandle,
                phase: phase,
                status: selectedStatus,
                isJoined: isJoined,
                isTransmitting: isTransmitting,
                canTransmitNow: canTransmitNow,
                pttTokenRegistrationKind: pttTokenRegistrationKind
            )
        }

        return nil
    }
}

struct SimulatorScenarioSelectedExpectation: Decodable {
    let handle: String?
    let phase: String?
    let status: String?
    let isJoined: Bool?
    let isTransmitting: Bool?
    let canTransmitNow: Bool?
    let pttTokenRegistrationKind: String?
}

struct SimulatorScenarioContactExpectation: Decodable {
    let handle: String
    let isOnline: Bool?
    let listState: String?
    let badgeStatus: String?
    let beepThreadProjection: String?
    let hasIncomingBeep: Bool?
    let hasOutgoingBeep: Bool?
    let requestCount: Int?
}

struct SimulatorScenarioBackendExpectation: Decodable {
    let channelStatus: String?
    let readiness: String?
    let remoteAudioReadiness: String?
    let remoteWakeCapabilityKind: String?
    let membership: String?
    let beepThreadProjection: String?
    let selfJoined: Bool?
    let peerJoined: Bool?
    let peerDeviceConnected: Bool?
    let canTransmit: Bool?
    let webSocketConnected: Bool?
}

enum SimulatorScenarioPhaseMatch {
    case exact
    case progressed
}

struct SimulatorScenarioDiagnosticsArtifact: Codable {
    let scenarioName: String
    let handle: String
    let deviceId: String
    let baseURL: String
    let selectedHandle: String?
    let appVersion: String
    let structuredEnvelope: DiagnosticsEnvelope
    let snapshot: String
    let transcript: String
}

struct ScheduledSimulatorScenarioAction {
    let actor: String
    let action: SimulatorScenarioAction
    let scheduledDelayMilliseconds: Int
    let declarationIndex: Int
    let deliveryIndex: Int
}

struct SimulatorScenarioRuntimeConfig: Decodable {
    let enabledUntilEpochSeconds: TimeInterval
    let filter: String?
    let baseURL: URL?
    let handleA: String?
    let handleB: String?
    let deviceIDA: String?
    let deviceIDB: String?
    let controlCommandTransportPolicy: TurboControlCommandTransportPolicy?
    let scenarioFile: String?
    let scenarioDirectory: String?
}

let simulatorScenarioRuntimeConfigURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".scenario-runtime-config.json", isDirectory: false)

func simulatorScenarioRuntimeConfigURLs() -> [URL] {
    var urls: [URL] = []
    if let override = ProcessInfo.processInfo.environment["SIMULATOR_SCENARIO_RUNTIME_CONFIG"],
       !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        urls.append(URL(fileURLWithPath: override))
    }
    urls.append(simulatorScenarioRuntimeConfigURL)
    return urls
}

func simulatorScenarioBackendTransportConfig(
    baseURL: URL
) -> TurboBackendHTTPTransportConfig {
    scenarioBaseURLIsLocal(baseURL)
        ? .failFastControlPlane
        : .hostedSimulatorScenario
}

func simulatorScenarioBackendConfig(
    baseURL: URL,
    handle: String,
    deviceID: String,
    controlCommandTransportPolicy: TurboControlCommandTransportPolicy = .automatic
) -> TurboBackendConfig {
    TurboBackendConfig(
        baseURL: baseURL,
        devUserHandle: handle,
        deviceID: deviceID,
        httpTransport: simulatorScenarioBackendTransportConfig(baseURL: baseURL),
        controlCommandTransportPolicy: controlCommandTransportPolicy
    )
}

@MainActor
func makeSimulatorScenarioViewModel(
    baseURL: URL,
    handle: String,
    deviceID: String,
    controlCommandTransportPolicy: TurboControlCommandTransportPolicy = .automatic
) -> PTTViewModel {
    let viewModel = PTTViewModel()
    viewModel.automaticDiagnosticsPublishEnabled = false
    viewModel.replaceBackendConfig(
        with: simulatorScenarioBackendConfig(
            baseURL: baseURL,
            handle: handle,
            deviceID: deviceID,
            controlCommandTransportPolicy: controlCommandTransportPolicy
        )
    )
    return viewModel
}

func loadSimulatorScenarioRuntimeConfig() -> SimulatorScenarioRuntimeConfig? {
    for url in simulatorScenarioRuntimeConfigURLs() {
        guard
            let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(SimulatorScenarioRuntimeConfig.self, from: data)
        else {
            continue
        }

        guard Date().timeIntervalSince1970 <= config.enabledUntilEpochSeconds else {
            continue
        }

        return config
    }
    return nil
}

func loadSimulatorScenarioSpecs(runtimeConfig: SimulatorScenarioRuntimeConfig) throws -> [SimulatorScenarioConfig] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let checkedInScenariosDirectory = root.appendingPathComponent("scenarios", isDirectory: true)
    let scenarioSource = try simulatorScenarioSource(
        runtimeConfig: runtimeConfig,
        defaultDirectory: checkedInScenariosDirectory
    )

    let decoder = JSONDecoder()
    let allSpecs = try scenarioSource.files.map { fileURL in
        let data = try Data(contentsOf: fileURL)
        let spec = try decoder.decode(SimulatorScenarioConfig.self, from: data)
        return applyScenarioRuntimeConfig(runtimeConfig, to: spec)
    }
    guard !allSpecs.isEmpty else {
        throw ScenarioFailure(message: "No simulator scenario specs were found in \(scenarioSource.description)")
    }

    let filter = runtimeConfig.filter?
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard let filter, !filter.isEmpty else {
        return try runnableScenarioSpecs(
            allSpecs,
            filter: nil,
            baseURLOverride: runtimeConfig.baseURL
        )
    }

    let filtered = try runnableScenarioSpecs(
        allSpecs,
        filter: filter,
        baseURLOverride: runtimeConfig.baseURL
    )
    guard !filtered.isEmpty else {
        throw ScenarioFailure(
            message: "No runnable simulator scenarios matched filter \(filter.joined(separator: ",")) in \(scenarioSource.description)"
        )
    }
    return filtered
}

struct SimulatorScenarioSource {
    let files: [URL]
    let description: String
}

func simulatorScenarioSource(
    runtimeConfig: SimulatorScenarioRuntimeConfig,
    defaultDirectory: URL
) throws -> SimulatorScenarioSource {
    let scenarioFile = runtimeConfig.scenarioFile?.trimmingCharacters(in: .whitespacesAndNewlines)
    let scenarioDirectory = runtimeConfig.scenarioDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let scenarioFile, !scenarioFile.isEmpty,
       let scenarioDirectory, !scenarioDirectory.isEmpty {
        throw ScenarioFailure(message: "Runtime config must use scenarioFile or scenarioDirectory, not both")
    }

    if let scenarioFile, !scenarioFile.isEmpty {
        let fileURL = simulatorScenarioRuntimeURL(from: scenarioFile, isDirectory: false)
        return SimulatorScenarioSource(files: [fileURL], description: fileURL.path)
    }

    let directoryURL: URL
    if let scenarioDirectory, !scenarioDirectory.isEmpty {
        directoryURL = simulatorScenarioRuntimeURL(from: scenarioDirectory, isDirectory: true)
    } else {
        directoryURL = defaultDirectory
    }

    let files =
        try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return SimulatorScenarioSource(files: files, description: directoryURL.path)
}

func simulatorScenarioRuntimeURL(from value: String, isDirectory: Bool) -> URL {
    if value.hasPrefix("/") {
        return URL(fileURLWithPath: value, isDirectory: isDirectory)
    }
    if let url = URL(string: value), url.scheme != nil {
        return url
    }
    return URL(fileURLWithPath: value, isDirectory: isDirectory)
}

struct SimulatorScenarioInvariantBaseline {
    let countsByInvariantID: [String: Int]

    init(violations: [DiagnosticsInvariantViolation]) {
        countsByInvariantID = Dictionary(
            grouping: violations,
            by: \.invariantID
        ).mapValues(\.count)
    }
}

@MainActor
func simulatorScenarioInvariantBaselines(
    viewModels: [String: PTTViewModel]
) -> [String: SimulatorScenarioInvariantBaseline] {
    Dictionary(uniqueKeysWithValues: viewModels.map { actor, viewModel in
        (
            actor,
            SimulatorScenarioInvariantBaseline(violations: viewModel.diagnostics.invariantViolations)
        )
    })
}

func applyScenarioRuntimeConfig(
    _ runtimeConfig: SimulatorScenarioRuntimeConfig,
    to spec: SimulatorScenarioConfig
) -> SimulatorScenarioConfig {
    let overriddenBaseURL = runtimeConfig.baseURL ?? spec.baseURL

    let participantOverrides: [String: (handle: String?, deviceId: String?)] = [
        "a": (
            runtimeConfig.handleA,
            runtimeConfig.deviceIDA
        ),
        "b": (
            runtimeConfig.handleB,
            runtimeConfig.deviceIDB
        ),
    ]

    let overriddenParticipants = Dictionary(uniqueKeysWithValues: spec.participants.map { actor, participant in
        let overrides = participantOverrides[actor] ?? (nil, nil)
        return (
            actor,
            SimulatorScenarioParticipant(
                handle: overrides.handle ?? participant.handle,
                deviceId: overrides.deviceId ?? participant.deviceId
            )
        )
    })

    return SimulatorScenarioConfig(
        name: spec.name,
        baseURL: overriddenBaseURL,
        requiresLocalBackend: spec.requiresLocalBackend,
        participants: overriddenParticipants,
        steps: spec.steps
    )
}

func runnableScenarioSpecs(
    _ specs: [SimulatorScenarioConfig],
    filter: [String]?,
    baseURLOverride: URL?
) throws -> [SimulatorScenarioConfig] {
    let requestedSpecs: [SimulatorScenarioConfig]
    if let filter, !filter.isEmpty {
        requestedSpecs = specs.filter { filter.contains($0.name) }
        guard !requestedSpecs.isEmpty else {
            throw ScenarioFailure(message: "No simulator scenarios matched filter \(filter.joined(separator: ","))")
        }
    } else {
        requestedSpecs = specs
    }

    var runnable: [SimulatorScenarioConfig] = []
    var localOnlyMismatches: [String] = []

    for spec in requestedSpecs {
        let effectiveBaseURL = baseURLOverride ?? spec.baseURL
        if spec.requiresLocalBackend == true && !scenarioBaseURLIsLocal(effectiveBaseURL) {
            localOnlyMismatches.append(spec.name)
            continue
        }
        runnable.append(spec)
    }

    if let filter, !filter.isEmpty, !localOnlyMismatches.isEmpty {
        throw ScenarioFailure(
            message: "Scenario(s) require a local backend: \(localOnlyMismatches.joined(separator: ", "))"
        )
    }

    return runnable
}

func scenarioBaseURLIsLocal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

@MainActor
func executeSimulatorScenario(_ spec: SimulatorScenarioConfig) async throws {
    print("Simulator scenario started: \(spec.name)")
    let controlCommandTransportPolicy =
        loadSimulatorScenarioRuntimeConfig()?.controlCommandTransportPolicy ?? .automatic
    for participant in spec.participants.values {
        try await resetAllDevelopmentState(baseURL: spec.baseURL, handle: participant.handle)
    }

    var viewModels = Dictionary(uniqueKeysWithValues: spec.participants.map { actor, participant in
        (
            actor,
            makeSimulatorScenarioViewModel(
                baseURL: spec.baseURL,
                handle: participant.handle,
                deviceID: participant.deviceId,
                controlCommandTransportPolicy: controlCommandTransportPolicy
            )
        )
    })
    var scenarioBackgroundTasks: [Task<Void, Never>] = []

    func currentParticipants() -> [PTTViewModel] {
        Array(viewModels.values)
    }

    do {
        for participant in currentParticipants() {
            await participant.initializeIfNeeded()
        }
        try await stabilizeScenario(currentParticipants())
        try await waitForScenario(
            "participants become mutually discoverable",
            participants: currentParticipants(),
            timeoutNanoseconds: 60_000_000_000
        ) {
            await scenarioParticipantsAreDiscoverable(spec: spec, viewModels: viewModels)
        }

        for step in spec.steps {
            let invariantBaselines = simulatorScenarioInvariantBaselines(viewModels: viewModels)
            let scheduledActions = try scheduledScenarioActions(for: step.actions)
            var elapsedMilliseconds = 0

            for scheduledAction in scheduledActions {
                let delayBeforeDelivery = scheduledAction.scheduledDelayMilliseconds - elapsedMilliseconds
                if delayBeforeDelivery > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delayBeforeDelivery) * 1_000_000)
                    elapsedMilliseconds = scheduledAction.scheduledDelayMilliseconds
                }

                let action = scheduledAction.action
                guard let participant = viewModels[action.actor] else {
                    throw ScenarioFailure(message: "Scenario references unknown actor \(action.actor)")
                }

                switch action.type {
                case "openFriend":
                    guard let friendActor = action.friend,
                          let friend = spec.participants[friendActor] else {
                        throw ScenarioFailure(message: "openFriend requires a known friend actor")
                    }
                    await participant.openFriend(reference: friend.handle)
                case "connect":
                    participant.joinChannel()
                case "disconnect":
                    participant.disconnect()
                case "declineBeep":
                    await participant.declineIncomingBeepForSelectedContact()
                case "cancelBeep":
                    await participant.cancelOutgoingBeepForSelectedContact()
                case "beginTransmit":
                    participant.beginTransmit()
                case "endTransmit":
                    participant.endTransmit()
                case "ensureDirectChannel":
                    guard let friendActor = action.friend,
                          let friend = spec.participants[friendActor],
                          let backend = participant.backendServices else {
                        throw ScenarioFailure(message: "ensureDirectChannel requires a known friend actor and backend")
                    }
                    let remoteUser = try await backend.resolveIdentity(reference: friend.handle)
                    _ = try await backend.directChannel(otherUserId: remoteUser.userId)
                    await participant.refreshContactSummaries()
                    if let selectedContactID = participant.selectedContact?.id {
                        await participant.refreshChannelState(for: selectedContactID)
                    }
                case "heartbeatPresence":
                    guard let backend = participant.backendServices else {
                        throw ScenarioFailure(message: "heartbeatPresence requires an initialized backend")
                    }
                    _ = try await backend.heartbeatPresence()
                case "refreshContactSummaries":
                    await participant.refreshContactSummaries()
                case "refreshBeeps":
                    await participant.refreshBeeps()
                case "refreshChannelState":
                    guard let selectedContactID = participant.selectedContact?.id else {
                        throw ScenarioFailure(message: "refreshChannelState requires a selected contact")
                    }
                    await participant.refreshChannelState(for: selectedContactID)
                case "refreshChannelStateAsync":
                    guard let selectedContactID = participant.selectedContact?.id else {
                        throw ScenarioFailure(message: "refreshChannelStateAsync requires a selected contact")
                    }
                    scenarioBackgroundTasks.append(
                        Task { @MainActor in
                            await participant.refreshChannelState(for: selectedContactID)
                        }
                    )
                case "captureDiagnostics":
                    participant.captureDiagnosticsState("scenario:capture")
                case "revokeEphemeralToken":
                    guard let selectedContact = participant.selectedContact,
                          let channelID = selectedContact.backendChannelId,
                          let backend = participant.backendServices else {
                        throw ScenarioFailure(message: "revokeEphemeralToken requires a selected backend channel")
                    }
                    _ = try await backend.revokeEphemeralToken(channelId: channelID)
                    await participant.refreshChannelState(for: selectedContact.id)
                case "injectStaleTransmitStopCompletion":
                    try await injectStaleTransmitStopCompletion(into: participant)
                case "resetTransportFaults":
                    participant.resetTransportFaults()
                case "setHTTPDelay":
                    guard let routeText = action.route,
                          let route = TransportFaultHTTPRoute(rawValue: routeText) else {
                        throw ScenarioFailure(message: "setHTTPDelay requires a known route")
                    }
                    let milliseconds = action.milliseconds ?? 0
                    guard milliseconds >= 0 else {
                        throw ScenarioFailure(message: "setHTTPDelay requires a non-negative milliseconds value")
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "setHTTPDelay requires count >= 1")
                    }
                    participant.setHTTPTransportDelay(route: route, milliseconds: milliseconds, count: count)
                case "setWebSocketSignalDelay":
                    guard let signalKindText = action.signalKind,
                          let signalKind = TurboSignalKind(rawValue: signalKindText) else {
                        throw ScenarioFailure(message: "setWebSocketSignalDelay requires a known signalKind")
                    }
                    let milliseconds = action.milliseconds ?? 0
                    guard milliseconds >= 0 else {
                        throw ScenarioFailure(
                            message: "setWebSocketSignalDelay requires a non-negative milliseconds value"
                        )
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "setWebSocketSignalDelay requires count >= 1")
                    }
                    participant.setIncomingWebSocketSignalDelay(
                        kind: signalKind,
                        milliseconds: milliseconds,
                        count: count
                    )
                case "dropNextWebSocketSignals":
                    guard let signalKindText = action.signalKind,
                          let signalKind = TurboSignalKind(rawValue: signalKindText) else {
                        throw ScenarioFailure(message: "dropNextWebSocketSignals requires a known signalKind")
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "dropNextWebSocketSignals requires count >= 1")
                    }
                    participant.dropNextIncomingWebSocketSignals(kind: signalKind, count: count)
                case "duplicateNextWebSocketSignals":
                    guard let signalKindText = action.signalKind,
                          let signalKind = TurboSignalKind(rawValue: signalKindText) else {
                        throw ScenarioFailure(message: "duplicateNextWebSocketSignals requires a known signalKind")
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "duplicateNextWebSocketSignals requires count >= 1")
                    }
                    participant.duplicateNextIncomingWebSocketSignals(kind: signalKind, count: count)
                case "reorderNextWebSocketSignals":
                    let signalKind: TurboSignalKind?
                    if let signalKindText = action.signalKind {
                        guard let parsedKind = TurboSignalKind(rawValue: signalKindText) else {
                            throw ScenarioFailure(message: "reorderNextWebSocketSignals requires a known signalKind")
                        }
                        signalKind = parsedKind
                    } else {
                        signalKind = nil
                    }
                    let count = action.count ?? 2
                    guard count >= 2 else {
                        throw ScenarioFailure(message: "reorderNextWebSocketSignals requires count >= 2")
                    }
                    participant.reorderNextIncomingWebSocketSignals(kind: signalKind, count: count)
                case "disconnectWebSocket":
                    participant.disconnectBackendWebSocket()
                    try await Task.sleep(nanoseconds: 150_000_000)
                    for viewModel in viewModels.values {
                        if let selectedContactID = viewModel.selectedContact?.id {
                            await viewModel.refreshChannelState(for: selectedContactID)
                            await viewModel.reconcileSelectedConversationIfNeeded()
                        }
                    }
                case "reconnectWebSocket":
                    guard let backend = participant.backendServices, backend.supportsWebSocket else {
                        throw ScenarioFailure(message: "reconnectWebSocket requires an initialized websocket backend")
                    }
                    backend.resumeWebSocket()
                    try await backend.waitForWebSocketConnection()
                case "backgroundApp":
                    participant.applicationStateOverride = .background
                    await participant.suspendForegroundMediaForBackgroundTransition(
                        reason: "scenario-background",
                        applicationState: .background
                    )
                    await participant.handleApplicationDidEnterBackground()
                case "foregroundApp":
                    participant.applicationStateOverride = .active
                    await participant.handleApplicationDidBecomeActive()
                case "lockApp":
                    participant.applicationStateOverride = .background
                    await participant.suspendForegroundMediaForBackgroundTransition(
                        reason: "scenario-lock",
                        applicationState: .background
                    )
                    await participant.handleApplicationDidEnterBackground()
                case "unlockApp":
                    participant.applicationStateOverride = .active
                    await participant.handleApplicationDidBecomeActive()
                case "setNetworkInterface":
                    guard let interfaceText = action.networkInterface,
                          let networkInterface = ConversationNetworkInterface(rawValue: interfaceText) else {
                        throw ScenarioFailure(message: "setNetworkInterface requires a known networkInterface")
                    }
                    let previousInterface = participant.localConversationNetworkInterface
                    participant.localConversationNetworkInterface = networkInterface
                    await participant.handleLocalNetworkPathChanged(
                        to: networkInterface,
                        previous: previousInterface,
                        source: action.reason ?? "scenario-network-change"
                    )
                    await participant.publishConversationParticipantTelemetryIfNeeded(
                        reason: action.reason ?? "scenario-network-change"
                    )
                    participant.captureDiagnosticsState("scenario:network:\(networkInterface.rawValue)")
                case "setMediaTransportPath":
                    guard let pathStateText = action.pathState,
                          let pathState = MediaTransportPathState(rawValue: pathStateText) else {
                        throw ScenarioFailure(message: "setMediaTransportPath requires a known pathState")
                    }
                    participant.mediaRuntime.updateTransportPathState(pathState)
                    participant.captureDiagnosticsState("scenario:path:\(pathState.rawValue)")
                case "activateDirectQuicPath":
                    try activateScenarioDirectQuicPath(participant)
                case "loseDirectQuicPath":
                    try await loseScenarioDirectQuicPath(
                        participant,
                        reason: action.reason ?? "scenario-network-change"
                    )
                case "reconnectBackend":
                    await participant.reconnectBackendControlPlane()
                case "reconcileSelectedConversation":
                    await participant.reconcileSelectedConversationIfNeeded()
                case "restartApp":
                    guard let scenarioParticipant = spec.participants[action.actor] else {
                        throw ScenarioFailure(message: "restartApp requires a known participant")
                    }
                    participant.resetLocalDevState(backendStatus: "Scenario restart")
                    let replacement = makeSimulatorScenarioViewModel(
                        baseURL: spec.baseURL,
                        handle: scenarioParticipant.handle,
                        deviceID: scenarioParticipant.deviceId,
                        controlCommandTransportPolicy: controlCommandTransportPolicy
                    )
                    viewModels[action.actor] = replacement
                    await replacement.initializeIfNeeded()
                    try await stabilizeScenario(currentParticipants())
                    try await waitForScenario(
                        "\(action.actor) restarts and becomes discoverable",
                        participants: currentParticipants(),
                        timeoutNanoseconds: 60_000_000_000
                    ) {
                        await scenarioParticipantsAreDiscoverable(spec: spec, viewModels: viewModels)
                    }
                case "wait":
                    let milliseconds = action.milliseconds ?? 0
                    guard milliseconds >= 0 else {
                        throw ScenarioFailure(message: "wait requires a non-negative milliseconds value")
                    }
                    try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                default:
                    throw ScenarioFailure(message: "Unknown scenario action type \(action.type)")
                }
            }

            if scenarioStepRequiresImmediateStabilization(step) {
                try await stabilizeScenario(currentParticipants())
            }

            if let expectations = step.expectEventually {
                try await waitForScenarioExpectations(
                    step.description,
                    expectations: expectations,
                    viewModels: viewModels,
                    invariantBaselines: invariantBaselines,
                    participants: currentParticipants()
                )
            }
        }

        for task in scenarioBackgroundTasks {
            await task.value
        }
        scenarioBackgroundTasks.removeAll()

        try await publishScenarioDiagnosticsArtifacts(spec: spec, viewModels: viewModels)
        await tearDownSimulatorScenarioParticipants(currentParticipants())
        print("Simulator scenario finished: \(spec.name)")
    } catch {
        scenarioBackgroundTasks.forEach { $0.cancel() }
        for task in scenarioBackgroundTasks {
            await task.value
        }
        try? await publishScenarioDiagnosticsArtifacts(spec: spec, viewModels: viewModels)
        await tearDownSimulatorScenarioParticipants(currentParticipants())
        print("Simulator scenario failed: \(spec.name): \(error)")
        throw error
    }
}

func scheduledScenarioActions(
    for actions: [SimulatorScenarioAction]
) throws -> [ScheduledSimulatorScenarioAction] {
    var scheduled: [ScheduledSimulatorScenarioAction] = []

    for (declarationIndex, action) in actions.enumerated() {
        let isDropped = action.drop ?? false
        if isDropped {
            continue
        }

        let initialDelayMilliseconds = action.delayMilliseconds ?? 0
        guard initialDelayMilliseconds >= 0 else {
            throw ScenarioFailure(message: "Scenario action \(action.type) requires a non-negative delayMilliseconds value")
        }

        let repeatCount = action.repeatCount ?? 1
        guard repeatCount >= 1 else {
            throw ScenarioFailure(message: "Scenario action \(action.type) requires repeatCount >= 1")
        }

        let repeatIntervalMilliseconds = action.repeatIntervalMilliseconds ?? 0
        guard repeatIntervalMilliseconds >= 0 else {
            throw ScenarioFailure(
                message: "Scenario action \(action.type) requires a non-negative repeatIntervalMilliseconds value"
            )
        }

        for deliveryIndex in 0..<repeatCount {
            scheduled.append(
                ScheduledSimulatorScenarioAction(
                    actor: action.actor,
                    action: action,
                    scheduledDelayMilliseconds: initialDelayMilliseconds + (deliveryIndex * repeatIntervalMilliseconds),
                    declarationIndex: declarationIndex,
                    deliveryIndex: deliveryIndex
                )
            )
        }
    }

    return scheduled.sorted { lhs, rhs in
        if lhs.scheduledDelayMilliseconds != rhs.scheduledDelayMilliseconds {
            return lhs.scheduledDelayMilliseconds < rhs.scheduledDelayMilliseconds
        }
        if lhs.declarationIndex != rhs.declarationIndex {
            let lhsOrder = lhs.action.reorderIndex ?? lhs.declarationIndex
            let rhsOrder = rhs.action.reorderIndex ?? rhs.declarationIndex
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.declarationIndex < rhs.declarationIndex
        }
        return lhs.deliveryIndex < rhs.deliveryIndex
    }
}

func scenarioStepRequiresImmediateStabilization(_ step: SimulatorScenarioStep) -> Bool {
    !step.actions.contains { action in
        action.type == "beginTransmit"
            || action.type == "endTransmit"
            || action.type == "captureDiagnostics"
    }
}

@MainActor
func publishScenarioDiagnosticsArtifacts(
    spec: SimulatorScenarioConfig,
    viewModels: [String: PTTViewModel]
) async throws {
    let scenarioRunID = UUID().uuidString.lowercased()
    for (actor, participant) in viewModels {
        let expectedDeviceID = spec.participants[actor]?.deviceId ?? "<missing>"
        let expectedHandle = spec.participants[actor]?.handle ?? participant.currentDevUserHandle
        let appVersion = "scenario:\(spec.name):\(scenarioRunID):\(expectedDeviceID)"
        let structuredEnvelope = participant.diagnosticsEnvelope(
            appVersion: appVersion,
            scenarioName: spec.name,
            scenarioRunID: scenarioRunID
        )
        let structuredEnvelopeJSON = try PTTViewModel.structuredDiagnosticsEnvelopeJSON(structuredEnvelope)
        let artifact = SimulatorScenarioDiagnosticsArtifact(
            scenarioName: spec.name,
            handle: expectedHandle,
            deviceId: expectedDeviceID,
            baseURL: spec.baseURL.absoluteString,
            selectedHandle: participant.selectedContact?.handle,
            appVersion: appVersion,
            structuredEnvelope: structuredEnvelope,
            snapshot: participant.diagnosticsSnapshot,
            transcript: participant.diagnosticsTranscriptText(structuredEnvelopeJSON: structuredEnvelopeJSON)
        )
        try await publishScenarioDiagnosticsArtifact(artifact)
        try await verifyScenarioDiagnosticsArtifactPublished(
            baseURL: spec.baseURL,
            handle: artifact.handle,
            deviceID: artifact.deviceId,
            expectedAppVersion: artifact.appVersion
        )
    }
}

@MainActor
func scenarioParticipantsAreDiscoverable(
    spec: SimulatorScenarioConfig,
    viewModels: [String: PTTViewModel]
) async -> Bool {
    for (actor, participant) in viewModels {
        guard let backend = participant.backendServices else { return false }
        for (friendActor, friend) in spec.participants where friendActor != actor {
            do {
                _ = try await backend.resolveIdentity(reference: friend.handle)
            } catch {
                return false
            }
        }
    }
    return true
}

@MainActor
func tearDownSimulatorScenarioParticipants(_ participants: [PTTViewModel]) async {
    for participant in participants {
        participant.resetLocalDevState(backendStatus: "Scenario teardown")
    }
    try? await Task.sleep(nanoseconds: 500_000_000)
}

@MainActor
func waitForScenarioExpectations(
    _ description: String,
    expectations: [String: SimulatorScenarioExpectation],
    viewModels: [String: PTTViewModel],
    invariantBaselines: [String: SimulatorScenarioInvariantBaseline],
    participants: [PTTViewModel],
    timeoutNanoseconds: UInt64 = 30_000_000_000,
    pollNanoseconds: UInt64 = 500_000_000
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    var lastMismatch: String?

    while DispatchTime.now().uptimeNanoseconds < deadline {
        let mismatch = scenarioExpectationMismatch(
            expectations,
            viewModels: viewModels,
            invariantBaselines: invariantBaselines
        )
        if mismatch == nil {
            return
        }
        lastMismatch = mismatch
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }

    let snapshotSummary = scenarioSnapshotSummary(participants)
    throw ScenarioFailure(
        message: """
        Timed out waiting for scenario step: \(description)
        Last mismatch: \(lastMismatch ?? "unknown")
        \(snapshotSummary)
        """
    )
}

@MainActor
func scenarioExpectationMismatch(
    _ expectations: [String: SimulatorScenarioExpectation],
    viewModels: [String: PTTViewModel],
    invariantBaselines: [String: SimulatorScenarioInvariantBaseline]
) -> String? {
    for actor in expectations.keys.sorted() {
        guard let expected = expectations[actor] else { continue }
        guard let participant = viewModels[actor] else {
            return "\(actor): unknown actor"
        }
        let projection = participant.stateMachineProjection

        var selectedPhaseMatch: SimulatorScenarioPhaseMatch = .exact
        if let selected = expected.selectedExpectation {
            guard let phaseMatch = scenarioSelectedExpectationMatches(selected, projection: projection) else {
                return "\(actor): selected expectation did not match"
            }
            selectedPhaseMatch = phaseMatch
        }

        if let contacts = expected.contacts,
           !scenarioContactExpectationsMatch(contacts, projection: projection)
        {
            return "\(actor): contact expectation did not match"
        }

        if let backend = expected.backend,
           !scenarioBackendExpectationMatches(
               backend,
               projection: projection,
               selectedPhaseMatch: selectedPhaseMatch
           )
        {
            return "\(actor): backend expectation did not match"
        }

        if let transportPathState = expected.transportPathState,
           !simulatorScenarioTransportPathMatches(
                expected: transportPathState,
                actual: participant.mediaTransportPathState.rawValue
           ) {
            return "\(actor): expected transportPathState \(transportPathState), got \(participant.mediaTransportPathState.rawValue)"
        }

        if let localNetworkInterface = expected.localNetworkInterface,
           participant.localConversationNetworkInterface.rawValue != localNetworkInterface {
            return "\(actor): expected localNetworkInterface \(localNetworkInterface), got \(participant.localConversationNetworkInterface.rawValue)"
        }

        if let invariantMismatch = scenarioInvariantExpectationMismatch(
            expected,
            baseline: invariantBaselines[actor] ?? SimulatorScenarioInvariantBaseline(violations: []),
            violations: participant.diagnostics.invariantViolations
        ) {
            return "\(actor): \(invariantMismatch)"
        }

        if let diagnosticsMismatch = scenarioDiagnosticsExpectationMismatch(
            expected,
            transcript: participant.diagnosticsTranscript
        ) {
            return "\(actor): \(diagnosticsMismatch)"
        }
    }

    return nil
}

func simulatorScenarioTransportPathMatches(expected: String, actual: String) -> Bool {
    if expected == actual { return true }
    return expected == "fast-relay" && actual == "fast-relay-tcp"
}

func scenarioDiagnosticsExpectationMismatch(
    _ expected: SimulatorScenarioExpectation,
    transcript: String
) -> String? {
    if let required = expected.diagnosticsContains {
        let missing = required
            .filter { !$0.isEmpty }
            .filter { !transcript.contains($0) }
        if !missing.isEmpty {
            return "expected diagnostics to contain: \(missing.joined(separator: ", "))"
        }
    }

    if let forbidden = expected.diagnosticsNotContains {
        let present = forbidden
            .filter { !$0.isEmpty }
            .filter { transcript.contains($0) }
        if !present.isEmpty {
            return "expected diagnostics not to contain: \(present.joined(separator: ", "))"
        }
    }

    return nil
}

func scenarioInvariantExpectationMismatch(
    _ expected: SimulatorScenarioExpectation,
    baseline: SimulatorScenarioInvariantBaseline,
    violations: [DiagnosticsInvariantViolation]
) -> String? {
    let newViolations = simulatorScenarioInvariantViolations(since: baseline, current: violations)
    let newInvariantIDs = Set(newViolations.map(\.invariantID))

    if let expectedIDs = expected.expectInvariant {
        let missing = expectedIDs
            .filter { !$0.isEmpty }
            .filter { !newInvariantIDs.contains($0) }
        if !missing.isEmpty {
            return "expected invariant(s) not emitted since step start: \(simulatorScenarioInvariantList(missing)); saw \(simulatorScenarioInvariantList(Array(newInvariantIDs)))"
        }
    }

    if let absentIDs = expected.eventuallyNoInvariant {
        let forbiddenIDs = Set(absentIDs.filter { !$0.isEmpty })
        let unexpected = newViolations
            .map(\.invariantID)
            .filter { forbiddenIDs.contains($0) }
        if !unexpected.isEmpty {
            return "expected no new invariant(s) since step start, saw: \(simulatorScenarioInvariantList(unexpected))"
        }
    }

    if expected.noInvariantViolations == true {
        let allowedIDs = Set((expected.allowInvariantDuringStep ?? []).filter { !$0.isEmpty })
        let unexpected = newViolations
            .map(\.invariantID)
            .filter { !allowedIDs.contains($0) }
        if !unexpected.isEmpty {
            return "expected no new invariant violations since step start, saw: \(simulatorScenarioInvariantList(unexpected))"
        }
    }

    return nil
}

func simulatorScenarioInvariantViolations(
    since baseline: SimulatorScenarioInvariantBaseline,
    current violations: [DiagnosticsInvariantViolation]
) -> [DiagnosticsInvariantViolation] {
    var remainingBaselineCounts = baseline.countsByInvariantID
    var newViolations: [DiagnosticsInvariantViolation] = []

    for violation in violations {
        let invariantID = violation.invariantID
        if let remaining = remainingBaselineCounts[invariantID], remaining > 0 {
            remainingBaselineCounts[invariantID] = remaining - 1
        } else {
            newViolations.append(violation)
        }
    }

    return newViolations
}

func simulatorScenarioInvariantList(_ invariantIDs: [String]) -> String {
    let unique = Set(invariantIDs.filter { !$0.isEmpty })
    guard !unique.isEmpty else { return "none" }
    return unique.sorted().joined(separator: ", ")
}

@MainActor
func activateScenarioDirectQuicPath(_ participant: PTTViewModel) throws {
    guard let selectedContact = participant.selectedContact else {
        throw ScenarioFailure(message: "activateDirectQuicPath requires a selected contact")
    }
    let channelID = selectedContact.backendChannelId ?? "scenario-channel-\(selectedContact.id.uuidString)"
    let attemptID = "scenario-direct-\(selectedContact.id.uuidString)"
    let peerDeviceID = participant.directQuicPeerDeviceID(for: selectedContact.id) ?? "scenario-peer-device"

    participant.mediaRuntime.replaceDirectQuicProbeController(with: DirectQuicProbeController())
    _ = participant.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
        contactID: selectedContact.id,
        channelID: channelID,
        attemptID: attemptID,
        peerDeviceID: peerDeviceID
    )
    _ = participant.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
        for: selectedContact.id,
        attemptID: attemptID,
        nominatedPath: makeScenarioDirectQuicNominatedPath(attemptID: attemptID)
    )
    participant.mediaRuntime.updateTransportPathState(.direct)
    participant.captureDiagnosticsState("scenario:direct-quic:active")
}

func makeScenarioDirectQuicNominatedPath(
    attemptID: String
) -> DirectQuicNominatedPath {
    DirectQuicNominatedPath(
        attemptId: attemptID,
        source: .outboundProbe,
        localPort: 50_000,
        remoteAddress: "203.0.113.20",
        remotePort: 54_321,
        remoteCandidateKind: .serverReflexive
    )
}

@MainActor
func loseScenarioDirectQuicPath(
    _ participant: PTTViewModel,
    reason: String
) async throws {
    guard let selectedContact = participant.selectedContact else {
        throw ScenarioFailure(message: "loseDirectQuicPath requires a selected contact")
    }
    guard let attempt = participant.mediaRuntime.directQuicUpgrade.attempt(for: selectedContact.id) else {
        throw ScenarioFailure(message: "loseDirectQuicPath requires an active Direct QUIC attempt")
    }

    await participant.handleDirectQuicMediaPathLost(
        for: selectedContact.id,
        attemptID: attempt.attemptId,
        reason: reason
    )
    participant.captureDiagnosticsState("scenario:direct-quic:path-lost")
}

@MainActor
func injectStaleTransmitStopCompletion(into participant: PTTViewModel) async throws {
    guard let selectedContact = participant.selectedContact else {
        throw ScenarioFailure(message: "injectStaleTransmitStopCompletion requires a selected contact")
    }

    let backendChannelID = selectedContact.backendChannelId ?? "scenario-channel-\(selectedContact.id.uuidString)"
    let request = TransmitRequestContext(
        contactID: selectedContact.id,
        contactHandle: selectedContact.handle,
        backendChannelID: backendChannelID,
        remoteUserID: "scenario-peer-user",
        channelUUID: UUID(),
        usesLocalHTTPBackend: false,
        backendSupportsWebSocket: true
    )
    let currentTarget = TransmitTarget(
        contactID: selectedContact.id,
        userID: "scenario-peer-user",
        deviceID: "scenario-peer-device",
        channelID: backendChannelID,
        transmitID: "scenario-current-transmit"
    )
    let staleTarget = TransmitTarget(
        contactID: selectedContact.id,
        userID: "scenario-peer-user",
        deviceID: "scenario-peer-device",
        channelID: backendChannelID,
        transmitID: "scenario-stale-transmit"
    )

    let previousEffectHandler = participant.transmitCoordinator.effectHandler
    participant.transmitCoordinator.effectHandler = nil
    defer {
        participant.transmitCoordinator.effectHandler = previousEffectHandler
        participant.transmitCoordinator.reset()
        participant.syncTransmitState()
    }

    await participant.transmitCoordinator.handle(.pressRequested(request))
    await participant.transmitCoordinator.handle(.beginSucceeded(currentTarget, request))
    await participant.transmitCoordinator.handle(.stopCompleted(staleTarget))
    participant.captureDiagnosticsState("scenario:stale-transmit-stop-completion")
}

func scenarioSelectedExpectationMatches(
    _ expected: SimulatorScenarioSelectedExpectation,
    projection: StateMachineProjection
) -> SimulatorScenarioPhaseMatch? {
    let selected = projection.selectedConversation

    if let handle = expected.handle,
       selected.selectedHandle != handle {
        return nil
    }

    var phaseMatch: SimulatorScenarioPhaseMatch = .exact
    if let phase = expected.phase {
        guard let matched = simulatorScenarioPhaseMatch(expected: phase, actual: selected.selectedPhase) else {
            return nil
        }
        phaseMatch = matched
    }

    if let status = expected.status,
       selected.statusMessage != status {
        return nil
    }

    if let isJoined = expected.isJoined,
       !(phaseMatch == .progressed && isJoined == false),
       selected.isJoined != isJoined,
       !(isJoined && scenarioAllowsWakeTimeoutFriendReadyForJoinedExpectation(selected)) {
        return nil
    }

    if let isTransmitting = expected.isTransmitting,
       !(phaseMatch == .progressed && isTransmitting == false) && selected.isTransmitting != isTransmitting {
        return nil
    }

    if let canTransmitNow = expected.canTransmitNow,
       !(phaseMatch == .progressed && canTransmitNow == false) && selected.canTransmitNow != canTransmitNow {
        return nil
    }
    if let pttTokenRegistrationKind = expected.pttTokenRegistrationKind,
       selected.pttTokenRegistrationKind != pttTokenRegistrationKind {
        return nil
    }

    return phaseMatch
}

func scenarioAllowsWakeTimeoutFriendReadyForJoinedExpectation(
    _ selected: SelectedConversationDiagnosticsSummary
) -> Bool {
    selected.selectedPhase == "friendReady"
        && selected.isJoined == false
        && selected.systemSession == "none"
        && selected.incomingWakeActivationState == "systemActivationTimedOutWaitingForForeground"
        && selected.backendSelfJoined == false
        && selected.backendPeerJoined == true
}

func scenarioContactExpectationsMatch(
    _ expectedContacts: [SimulatorScenarioContactExpectation],
    projection: StateMachineProjection
) -> Bool {
    for expected in expectedContacts {
        guard let contact = projection.contact(handle: expected.handle) else {
            return false
        }

        if let isOnline = expected.isOnline,
           contact.isOnline != isOnline {
            return false
        }
        if let listState = expected.listState,
           contact.listState != listState {
            return false
        }
        if let badgeStatus = expected.badgeStatus,
           contact.badgeStatus != badgeStatus {
            return false
        }
        if let beepThreadProjection = expected.beepThreadProjection,
           contact.beepThreadProjection != beepThreadProjection {
            return false
        }
        if let hasIncomingBeep = expected.hasIncomingBeep,
           contact.hasIncomingBeep != hasIncomingBeep {
            return false
        }
        if let hasOutgoingBeep = expected.hasOutgoingBeep,
           contact.hasOutgoingBeep != hasOutgoingBeep {
            return false
        }
        if let requestCount = expected.requestCount,
           contact.requestCount != requestCount {
            return false
        }
    }

    return true
}

func scenarioBackendExpectationMatches(
    _ expected: SimulatorScenarioBackendExpectation,
    projection: StateMachineProjection,
    selectedPhaseMatch: SimulatorScenarioPhaseMatch = .exact
) -> Bool {
    let selected = projection.selectedConversation

    if let channelStatus = expected.channelStatus,
       !simulatorScenarioBackendStatusMatches(
           expected: channelStatus,
           actual: selected.backendChannelStatus,
           selectedPhaseMatch: selectedPhaseMatch
       ) {
        return false
    }
    if let readiness = expected.readiness,
       !simulatorScenarioBackendReadinessMatches(
           expected: readiness,
           actual: selected.backendReadiness,
           selectedPhaseMatch: selectedPhaseMatch
       ) {
        return false
    }
    if let remoteAudioReadiness = expected.remoteAudioReadiness,
       selected.remoteAudioReadiness != remoteAudioReadiness {
        return false
    }
    if let remoteWakeCapabilityKind = expected.remoteWakeCapabilityKind,
       selected.remoteWakeCapabilityKind != remoteWakeCapabilityKind {
        return false
    }
    if let membership = expected.membership,
       selected.backendMembership != membership {
        return false
    }
    if let beepThreadProjection = expected.beepThreadProjection,
       selected.backendBeepThreadProjection != beepThreadProjection {
        return false
    }
    if let selfJoined = expected.selfJoined,
       selected.backendSelfJoined != selfJoined {
        return false
    }
    if let peerJoined = expected.peerJoined,
       selected.backendPeerJoined != peerJoined {
        return false
    }
    if let peerDeviceConnected = expected.peerDeviceConnected,
       selected.backendPeerDeviceConnected != peerDeviceConnected {
        return false
    }
    if let canTransmit = expected.canTransmit,
       !simulatorScenarioBackendCanTransmitMatches(
           expected: canTransmit,
           actual: selected.backendCanTransmit,
           selectedPhaseMatch: selectedPhaseMatch
       ) {
        return false
    }
    if let webSocketConnected = expected.webSocketConnected,
       projection.isWebSocketConnected != webSocketConnected {
        return false
    }

    return true
}

func simulatorScenarioBackendStatusMatches(
    expected: String,
    actual: String?,
    selectedPhaseMatch: SimulatorScenarioPhaseMatch
) -> Bool {
    guard let actual else { return false }
    if actual == expected { return true }
    guard selectedPhaseMatch == .progressed else { return false }

    switch (expected, actual) {
    case ("waiting-for-peer", "ready"):
        return true
    default:
        return false
    }
}

func simulatorScenarioBackendReadinessMatches(
    expected: String,
    actual: String?,
    selectedPhaseMatch: SimulatorScenarioPhaseMatch
) -> Bool {
    guard let actual else { return false }
    if actual == expected { return true }
    guard selectedPhaseMatch == .progressed else { return false }

    switch (expected, actual) {
    case ("waiting-for-self", "ready"),
         ("waiting-for-peer", "ready"):
        return true
    default:
        return false
    }
}

func simulatorScenarioBackendCanTransmitMatches(
    expected: Bool,
    actual: Bool?,
    selectedPhaseMatch: SimulatorScenarioPhaseMatch
) -> Bool {
    guard let actual else { return false }
    if actual == expected { return true }
    return selectedPhaseMatch == .progressed && expected == false && actual == true
}

func simulatorScenarioPhaseMatch<Phase: CustomStringConvertible>(
    expected expectedPhase: String,
    actual actualPhase: Phase
) -> SimulatorScenarioPhaseMatch? {
    let actual = String(describing: actualPhase)
    if actual == expectedPhase {
        return .exact
    }
    if expectedPhase == "waitingForPeer",
       actual == "wakeReady" {
        return .progressed
    }

    guard
        let expectedRank = simulatorScenarioTransientPhaseRank(expectedPhase),
        let actualRank = simulatorScenarioTransientPhaseRank(actual)
    else {
        return nil
    }

    return actualRank >= expectedRank ? .progressed : nil
}

func simulatorScenarioTransientPhaseRank(_ phase: String) -> Int? {
    switch phase {
    case "outgoingBeep", "incomingBeep":
        return 0
    case "friendReady", "waitingForPeer":
        return 1
    case "ready":
        return 2
    default:
        return nil
    }
}

enum DevelopmentResetEndpoint {
    case resetAll
    case resetState

    var path: String {
        switch self {
        case .resetAll:
            return "/v1/dev/reset-all"
        case .resetState:
            return "/v1/dev/reset-state"
        }
    }

    var label: String {
        switch self {
        case .resetAll:
            return "reset-all"
        case .resetState:
            return "reset-state"
        }
    }
}

func resetAllDevelopmentState(baseURL: URL, handle: String) async throws {
    if shouldUseResetStateOnly(baseURL: baseURL) {
        try await performDevelopmentReset(
            endpoint: .resetState,
            baseURL: baseURL,
            handle: handle,
            maxAttempts: 3
        )
        return
    }

    do {
        try await performDevelopmentReset(
            endpoint: .resetAll,
            baseURL: baseURL,
            handle: handle,
            maxAttempts: 2
        )
    } catch let error as ScenarioFailure {
        let message = error.message.lowercased()
        let shouldFallbackToResetState =
            message.contains("reset-all")
            && (message.contains("failed") || message.contains("timed out"))
        guard shouldFallbackToResetState else { throw error }

        try await performDevelopmentReset(
            endpoint: .resetState,
            baseURL: baseURL,
            handle: handle,
            maxAttempts: 5
        )
    }
}

func shouldUseResetStateOnly(baseURL: URL) -> Bool {
    guard let host = baseURL.host?.lowercased() else { return false }
    return host != "localhost" && host != "127.0.0.1"
}

func performDevelopmentReset(
    endpoint: DevelopmentResetEndpoint,
    baseURL: URL,
    handle: String,
    maxAttempts: Int
) async throws {
    let timeoutInterval: TimeInterval = switch endpoint {
    case .resetAll:
        8
    case .resetState:
        12
    }
    for attempt in 1...maxAttempts {
        let url = baseURL.appending(path: endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue(handle, forHTTPHeaderField: "x-turbo-user-handle")
        request.setValue("Bearer \(handle)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ScenarioFailure(message: "\(endpoint.label) for \(handle) returned a non-HTTP response")
            }
            if (200..<300).contains(httpResponse.statusCode) {
                return
            }

            let payload = String(data: data, encoding: .utf8) ?? "<empty>"
            let isRetriable = httpResponse.statusCode >= 500 && attempt < maxAttempts
            if isRetriable {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                continue
            }

            throw ScenarioFailure(message: "\(endpoint.label) for \(handle) failed: \(httpResponse.statusCode) \(payload)")
        } catch let scenarioFailure as ScenarioFailure {
            throw scenarioFailure
        } catch {
            let isFinalAttempt = attempt == maxAttempts
            if isFinalAttempt {
                throw ScenarioFailure(
                    message: "\(endpoint.label) for \(handle) failed after \(maxAttempts) attempts: \(error.localizedDescription)"
                )
            }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
        }
    }

    throw ScenarioFailure(message: "\(endpoint.label) for \(handle) failed after \(maxAttempts) attempts")
}

@MainActor
func stabilizeScenario(_ participants: [PTTViewModel]) async throws {
    for participant in participants {
        await participant.refreshContactSummaries()
        await participant.refreshBeeps()
        if let selectedContactID = participant.selectedContactId {
            await participant.refreshChannelState(for: selectedContactID)
        }
        participant.updateStatusForSelectedContact()
    }
    try await Task.sleep(nanoseconds: 300_000_000)
}

@MainActor
func requireSelectedContactID(in viewModel: PTTViewModel, expectedHandle: String) throws -> UUID {
    guard let selectedContact = viewModel.selectedContact else {
        throw ScenarioFailure(message: "Expected selected contact \(expectedHandle), but selection was empty")
    }
    guard selectedContact.handle == expectedHandle else {
        throw ScenarioFailure(
            message: "Expected selected contact \(expectedHandle), got \(selectedContact.handle)"
        )
    }
    return selectedContact.id
}

@MainActor
func waitForScenario(
    _ description: String,
    participants: [PTTViewModel],
    timeoutNanoseconds: UInt64 = 30_000_000_000,
    pollNanoseconds: UInt64 = 500_000_000,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
    let snapshotSummary = scenarioSnapshotSummary(participants)
    throw ScenarioFailure(
        message: "Timed out waiting for scenario step: \(description)\n\(snapshotSummary)"
    )
}

func waitForCondition(
    _ description: String,
    timeoutNanoseconds: UInt64 = 30_000_000_000,
    pollNanoseconds: UInt64 = 500_000_000,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }

    throw ScenarioFailure(message: "Timed out waiting for condition: \(description)")
}

@MainActor
func recordHostedBackendClientProbeRequest(
    name: String,
    into measurements: inout [HostedBackendClientProbeHTTPMeasurement],
    operation: () async throws -> Void
) async throws {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    do {
        try await operation()
        measurements.append(
            HostedBackendClientProbeHTTPMeasurement(
                name: name,
                elapsedMs: Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000),
                succeeded: true,
                error: nil
            )
        )
    } catch {
        measurements.append(
            HostedBackendClientProbeHTTPMeasurement(
                name: name,
                elapsedMs: Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000),
                succeeded: false,
                error: error.localizedDescription
            )
        )
        throw error
    }
}

let hostedBackendClientProbeISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

@MainActor
func scenarioSnapshotSummary(_ participants: [PTTViewModel]) -> String {
    participants.map { participant in
        let projection = participant.stateMachineProjection
        let fields = [
            "devUserHandle=\(participant.currentDevUserHandle)",
            "selectedContact=\(projection.selectedConversation.selectedHandle ?? "none")",
            "selectedConversationPhase=\(projection.selectedConversation.selectedPhase)",
            "selectedConversationStatus=\(projection.selectedConversation.statusMessage)",
            "pendingAction=\(String(describing: participant.conversationActionCoordinator.pendingAction))",
            "isJoined=\(projection.selectedConversation.isJoined)",
            "isTransmitting=\(projection.selectedConversation.isTransmitting)",
            "backendChannelStatus=\(projection.selectedConversation.backendChannelStatus ?? "none")",
            "backendReadiness=\(projection.selectedConversation.backendReadiness ?? "none")",
            "backendSelfJoined=\(projection.selectedConversation.backendSelfJoined.map(String.init(describing:)) ?? "none")",
            "backendPeerJoined=\(projection.selectedConversation.backendPeerJoined.map(String.init(describing:)) ?? "none")",
            "backendPeerDeviceConnected=\(projection.selectedConversation.backendPeerDeviceConnected.map(String.init(describing:)) ?? "none")",
            "backendCanTransmit=\(projection.selectedConversation.backendCanTransmit.map(String.init(describing:)) ?? "none")",
            "remoteAudioReadiness=\(projection.selectedConversation.remoteAudioReadiness ?? "unknown")",
            "remoteWakeCapability=\(projection.selectedConversation.remoteWakeCapability ?? "unavailable")",
            "systemSession=\(String(describing: participant.systemSessionState))",
            "localJoinFailure=\(participant.pttCoordinator.state.lastJoinFailure.map { String(describing: $0) } ?? "none")",
        ]
        let contactDetails = projection.contacts.map { contact in
            "contact[\(contact.handle)]={online:\(contact.isOnline),list:\(contact.listState),section:\(contact.listSection),presence:\(contact.presencePill),badge:\(contact.badgeStatus ?? "none")}"
        }
        return (fields + contactDetails).joined(separator: " ")
    }
    .joined(separator: "\n")
}

struct HostedBackendClientProbeRuntime {
    let baseURL: URL
    let handle: String
    let deviceID: String
    let durationSeconds: Int
    let heartbeatIntervalSeconds: Int
    let telemetryIntervalSeconds: Int
    let artifactURL: URL

    var durationNanoseconds: UInt64 {
        UInt64(max(durationSeconds, 1)) * 1_000_000_000
    }

    var heartbeatIntervalNanoseconds: UInt64 {
        guard heartbeatIntervalSeconds > 0 else { return 0 }
        return UInt64(heartbeatIntervalSeconds) * 1_000_000_000
    }

    var telemetryIntervalNanoseconds: UInt64 {
        guard telemetryIntervalSeconds > 0 else { return 0 }
        return UInt64(telemetryIntervalSeconds) * 1_000_000_000
    }
}

struct HostedBackendClientProbeRuntimeConfig: Codable {
    let enabledUntilEpochSeconds: TimeInterval
    let baseURL: URL
    let handle: String?
    let deviceID: String?
    let durationSeconds: Int?
    let heartbeatIntervalSeconds: Int?
    let telemetryIntervalSeconds: Int?
    let outputPath: String?
    let suppressSharedAppBackendBootstrap: Bool?
}

struct HostedBackendClientProbeRuntimeConfigSummary: Codable {
    let mode: String?
    let supportsWebSocket: Bool?
    let supportsSignalSessionIds: Bool?

    init(
        mode: String? = nil,
        supportsWebSocket: Bool? = nil,
        supportsSignalSessionIds: Bool? = nil
    ) {
        self.mode = mode
        self.supportsWebSocket = supportsWebSocket
        self.supportsSignalSessionIds = supportsSignalSessionIds
    }

    init(_ runtimeConfig: TurboBackendRuntimeConfig) {
        self.init(
            mode: runtimeConfig.mode,
            supportsWebSocket: runtimeConfig.supportsWebSocket,
            supportsSignalSessionIds: runtimeConfig.supportsSignalSessionIds
        )
    }
}

struct HostedBackendClientProbeTimedValue<Value: Codable>: Codable {
    let elapsedMs: Int
    let value: Value
}

struct HostedBackendClientProbeStatusNotice: Codable {
    let status: String
    let deviceId: String?
    let sessionId: String?
    let channelId: String?
    let fromUserId: String?
    let fromDeviceId: String?
    let reason: String?
    let leftAt: String?

    init(_ notice: TurboWebSocketStatusNotice) {
        status = notice.status
        deviceId = notice.deviceId
        sessionId = notice.sessionId
        channelId = notice.channelId
        fromUserId = notice.fromUserId
        fromDeviceId = notice.fromDeviceId
        reason = notice.reason
        leftAt = notice.leftAt
    }
}

struct HostedBackendClientProbeHTTPMeasurement: Codable {
    let name: String
    let elapsedMs: Int
    let succeeded: Bool
    let error: String?
}

struct HostedBackendClientProbeArtifact: Codable {
    let startedAt: String
    let baseURL: String
    let handle: String
    let deviceID: String
    let durationSeconds: Int
    let heartbeatIntervalSeconds: Int
    let telemetryIntervalSeconds: Int
    let runtimeConfig: HostedBackendClientProbeRuntimeConfigSummary
    let authenticatedHandle: String
    let authenticatedUserID: String
    let stateTransitions: [HostedBackendClientProbeTimedValue<String>]
    let serverNotices: [HostedBackendClientProbeTimedValue<String>]
    let statusNotices: [HostedBackendClientProbeTimedValue<HostedBackendClientProbeStatusNotice>]
    let auxiliaryRequests: [HostedBackendClientProbeHTTPMeasurement]
    let failureSummary: String?
}

@MainActor
func hostedBackendClientProbeRuntime() -> HostedBackendClientProbeRuntime? {
    let runtimeConfigURL = URL(
        fileURLWithPath: "/tmp/turbo-debug/hosted_backend_client_probe_runtime.json"
    )
    guard
        let data = try? Data(contentsOf: runtimeConfigURL),
        let config = try? JSONDecoder().decode(HostedBackendClientProbeRuntimeConfig.self, from: data)
    else {
        return nil
    }

    guard Date().timeIntervalSince1970 <= config.enabledUntilEpochSeconds else {
        return nil
    }

    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let handle = config.handle ?? "@wsprobe\(suffix.prefix(10))"
    let deviceID = config.deviceID ?? "ios-client-probe-\(suffix.prefix(12))"
    let artifactURL = URL(
        fileURLWithPath: config.outputPath ?? "/tmp/turbo-debug/hosted_backend_client_probe_latest.json"
    )

    return HostedBackendClientProbeRuntime(
        baseURL: config.baseURL,
        handle: handle,
        deviceID: deviceID,
        durationSeconds: config.durationSeconds ?? 60,
        heartbeatIntervalSeconds: config.heartbeatIntervalSeconds ?? 20,
        telemetryIntervalSeconds: config.telemetryIntervalSeconds ?? 20,
        artifactURL: artifactURL
    )
}

func writeHostedBackendClientProbeArtifact(
    _ artifact: HostedBackendClientProbeArtifact,
    to artifactURL: URL
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(artifact)
    let directory = artifactURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: artifactURL)
}

func publishScenarioDiagnosticsArtifact(_ artifact: SimulatorScenarioDiagnosticsArtifact) async throws {
    guard let baseURL = URL(string: artifact.baseURL) else {
        throw ScenarioFailure(message: "Invalid base URL for scenario diagnostics upload: \(artifact.baseURL)")
    }
    let endpointURL = baseURL.appending(path: "/v1/dev/diagnostics")
    let requestPayload: [String: Any?] = [
        "deviceId": artifact.deviceId,
        "appVersion": artifact.appVersion,
        "backendBaseURL": artifact.baseURL,
        "selectedHandle": artifact.selectedHandle,
        "snapshot": artifact.snapshot,
        "transcript": artifact.transcript,
    ]
    let body = try JSONSerialization.data(withJSONObject: requestPayload.compactMapValues { $0 })
    var request = URLRequest(url: endpointURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(artifact.handle, forHTTPHeaderField: "x-turbo-user-handle")
    request.setValue("Bearer \(artifact.handle)", forHTTPHeaderField: "Authorization")
    request.httpBody = body

    let (data, _) = try await performScenarioDiagnosticsRequest(
        request,
        label: "upload",
        handle: artifact.handle,
        deviceID: artifact.deviceId
    )
    let responsePayload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let report = responsePayload?["report"] as? [String: Any]
    let reportedDeviceID = report?["deviceId"] as? String
    let reportedAppVersion = report?["appVersion"] as? String
    guard reportedDeviceID == artifact.deviceId,
          reportedAppVersion == artifact.appVersion else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw ScenarioFailure(
            message: "Scenario diagnostics upload returned unexpected report for \(artifact.handle) expected device \(artifact.deviceId) appVersion \(artifact.appVersion) got device \(reportedDeviceID ?? "none") appVersion \(reportedAppVersion ?? "none"): \(body)"
        )
    }
}

func verifyScenarioDiagnosticsArtifactPublished(
    baseURL: URL,
    handle: String,
    deviceID: String,
    expectedAppVersion: String,
    maxAttempts: Int = 10
) async throws {
    let endpointURL = baseURL.appending(path: "/v1/dev/diagnostics/latest/\(deviceID)/")
    for attempt in 1...maxAttempts {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue(handle, forHTTPHeaderField: "x-turbo-user-handle")
        request.setValue("Bearer \(handle)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await performScenarioDiagnosticsRequest(
            request,
            label: "verification",
            handle: handle,
            deviceID: deviceID
        )
        let responsePayload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let report = responsePayload?["report"] as? [String: Any]
        let reportedDeviceID = report?["deviceId"] as? String
        let reportedAppVersion = report?["appVersion"] as? String
        if reportedDeviceID == deviceID,
           reportedAppVersion == expectedAppVersion {
            return
        }
        if attempt < maxAttempts {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            continue
        }

        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw ScenarioFailure(
            message: "Scenario diagnostics verification returned unexpected report for \(handle) expected device \(deviceID) appVersion \(expectedAppVersion) got device \(reportedDeviceID ?? "none") appVersion \(reportedAppVersion ?? "none"): \(body)"
        )
    }

    throw ScenarioFailure(
        message: "Scenario diagnostics verification failed for \(handle) \(deviceID) after \(maxAttempts) attempts"
    )
}

func performScenarioDiagnosticsRequest(
    _ request: URLRequest,
    label: String,
    handle: String,
    deviceID: String,
    maxAttempts: Int = 3
) async throws -> (Data, HTTPURLResponse) {
    for attempt in 1...maxAttempts {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ScenarioFailure(
                    message: "Scenario diagnostics \(label) returned a non-HTTP response for \(handle) \(deviceID)"
                )
            }
            if (200..<300).contains(httpResponse.statusCode) {
                return (data, httpResponse)
            }

            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            let isRetriable = httpResponse.statusCode >= 500 && attempt < maxAttempts
            if isRetriable {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
                continue
            }
            throw ScenarioFailure(
                message: "Scenario diagnostics \(label) failed for \(handle) \(deviceID): \(httpResponse.statusCode) \(body)"
            )
        } catch let scenarioFailure as ScenarioFailure {
            throw scenarioFailure
        } catch {
            if attempt == maxAttempts {
                throw ScenarioFailure(
                    message: "Scenario diagnostics \(label) failed for \(handle) \(deviceID) after \(maxAttempts) attempts: \(error.localizedDescription)"
                )
            }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
        }
    }

    throw ScenarioFailure(
        message: "Scenario diagnostics \(label) failed for \(handle) \(deviceID) after \(maxAttempts) attempts"
    )
}
