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

@MainActor
struct SimulatorScenarioTests {
    @Test func simulatorDistributedJoinScenario() async throws {
        guard let runtimeConfig = loadSimulatorScenarioRuntimeConfig() else {
            return
        }
        let specs = try loadSimulatorScenarioSpecs(runtimeConfig: runtimeConfig)
        for spec in specs {
            try await executeSimulatorScenario(spec)
        }
    }
}

@MainActor
struct SimulatorScenarioPlannerTests {
    @Test func scenarioActionDecodesOpenFriendActor() throws {
        let data = Data(
            """
            {
              "name": "open_friend_decode",
              "baseURL": "https://beepbeep.to",
              "participants": {
                "a": { "handle": "@avery", "deviceId": "device-a" },
                "b": { "handle": "@blake", "deviceId": "device-b" }
              },
              "steps": [
                {
                  "description": "open friend",
                  "actions": [
                    { "actor": "a", "type": "openFriend", "friend": "b" }
                  ]
                }
              ]
            }
            """.utf8
        )

        let spec = try JSONDecoder().decode(SimulatorScenarioConfig.self, from: data)
        let action = try #require(spec.steps.first?.actions.first)

        #expect(action.type == "openFriend")
        #expect(action.friend == "b")
    }

    @Test func scenarioPlannerSupportsDelayDropAndDuplicateDelivery() throws {
        let scheduled = try scheduledScenarioActions(
            for: [
                SimulatorScenarioAction(
                    actor: "a",
                    type: "connect",
                    friend: nil,
                    route: nil,
                    signalKind: nil,
                    milliseconds: nil,
                    count: nil,
                    delayMilliseconds: 400,
                    repeatCount: nil,
                    repeatIntervalMilliseconds: nil,
                    reorderIndex: nil,
                    drop: nil
                ),
                SimulatorScenarioAction(
                    actor: "b",
                    type: "refreshContactSummaries",
                    friend: nil,
                    route: nil,
                    signalKind: nil,
                    milliseconds: nil,
                    count: nil,
                    delayMilliseconds: nil,
                    repeatCount: 2,
                    repeatIntervalMilliseconds: 150,
                    reorderIndex: nil,
                    drop: nil
                ),
                SimulatorScenarioAction(
                    actor: "a",
                    type: "refreshBeeps",
                    friend: nil,
                    route: nil,
                    signalKind: nil,
                    milliseconds: nil,
                    count: nil,
                    delayMilliseconds: 50,
                    repeatCount: nil,
                    repeatIntervalMilliseconds: nil,
                    reorderIndex: nil,
                    drop: true
                ),
            ]
        )

        #expect(scheduled.count == 3)
        #expect(scheduled.map { $0.actor } == ["b", "b", "a"])
        #expect(scheduled.map { $0.scheduledDelayMilliseconds } == [0, 150, 400])
        #expect(scheduled.map { $0.deliveryIndex } == [0, 1, 0])
        #expect(scheduled.map { $0.action.type } == ["refreshContactSummaries", "refreshContactSummaries", "connect"])
    }

    @Test func scenarioPlannerRejectsNegativeDelay() throws {
        #expect(throws: ScenarioFailure.self) {
            _ = try scheduledScenarioActions(
                for: [
                    SimulatorScenarioAction(
                        actor: "a",
                        type: "connect",
                        friend: nil,
                        route: nil,
                        signalKind: nil,
                        milliseconds: nil,
                        count: nil,
                        delayMilliseconds: -1,
                        repeatCount: nil,
                        repeatIntervalMilliseconds: nil,
                        reorderIndex: nil,
                        drop: nil
                    )
                ]
            )
        }
    }

    @Test func scenarioBackendExpectationAcceptsReadyWhenPhaseHasProgressed() {
        #expect(
            simulatorScenarioBackendStatusMatches(
                expected: "waiting-for-peer",
                actual: "ready",
                selectedPhaseMatch: .progressed
            )
        )
        #expect(
            simulatorScenarioBackendReadinessMatches(
                expected: "waiting-for-self",
                actual: "ready",
                selectedPhaseMatch: .progressed
            )
        )
        #expect(
            simulatorScenarioBackendCanTransmitMatches(
                expected: false,
                actual: true,
                selectedPhaseMatch: .progressed
            )
        )

        #expect(
            !simulatorScenarioBackendReadinessMatches(
                expected: "waiting-for-self",
                actual: "ready",
                selectedPhaseMatch: .exact
            )
        )
        #expect(
            !simulatorScenarioBackendCanTransmitMatches(
                expected: false,
                actual: true,
                selectedPhaseMatch: .exact
            )
        )
    }

    @Test func scenarioInvariantExpectationsUseStepBaseline() throws {
        let expectation = try JSONDecoder().decode(
            SimulatorScenarioExpectation.self,
            from: Data(
                """
                {
                  "noInvariantViolations": true,
                  "expectInvariant": ["selected.ready_without_join"],
                  "eventuallyNoInvariant": ["selected.backend_ready_ui_not_live"],
                  "allowInvariantDuringStep": ["selected.ready_without_join"]
                }
                """.utf8
            )
        )
        let preexisting = DiagnosticsInvariantViolation(
            invariantID: "selected.ready_without_join",
            scope: .local,
            message: "preexisting"
        )
        let newlyAllowed = DiagnosticsInvariantViolation(
            invariantID: "selected.ready_without_join",
            scope: .local,
            message: "newly allowed"
        )
        let baseline = SimulatorScenarioInvariantBaseline(violations: [preexisting])

        #expect(
            scenarioInvariantExpectationMismatch(
                expectation,
                baseline: baseline,
                violations: [newlyAllowed, preexisting]
            ) == nil
        )

        let strictExpectation = try JSONDecoder().decode(
            SimulatorScenarioExpectation.self,
            from: Data(
                """
                {
                  "noInvariantViolations": true
                }
                """.utf8
            )
        )
        let strictMismatch = scenarioInvariantExpectationMismatch(
            strictExpectation,
            baseline: baseline,
            violations: [newlyAllowed, preexisting]
        )
        #expect(strictMismatch?.contains("selected.ready_without_join") == true)

        let missingExpectation = try JSONDecoder().decode(
            SimulatorScenarioExpectation.self,
            from: Data(
                """
                {
                  "expectInvariant": ["selected.backend_ready_ui_not_live"]
                }
                """.utf8
            )
        )
        let missingMismatch = scenarioInvariantExpectationMismatch(
            missingExpectation,
            baseline: baseline,
            violations: [newlyAllowed, preexisting]
        )
        #expect(missingMismatch?.contains("selected.backend_ready_ui_not_live") == true)
    }

    @Test func scenarioSourceSupportsRuntimeScenarioFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turbo-scenario-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scenarioFile = directory.appendingPathComponent("generated.json")
        try Data("{}".utf8).write(to: scenarioFile)

        let source = try simulatorScenarioSource(
            runtimeConfig: SimulatorScenarioRuntimeConfig(
                enabledUntilEpochSeconds: Date().timeIntervalSince1970 + 60,
                filter: nil,
                baseURL: nil,
                handleA: nil,
                handleB: nil,
                deviceIDA: nil,
                deviceIDB: nil,
                controlCommandTransportPolicy: nil,
                scenarioFile: scenarioFile.path,
                scenarioDirectory: nil
            ),
            defaultDirectory: directory
        )

        #expect(source.files == [scenarioFile])
        #expect(source.description == scenarioFile.path)
    }

    @Test func scenarioSourceSupportsRuntimeScenarioDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turbo-scenario-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("b.json")
        let second = directory.appendingPathComponent("a.json")
        let ignored = directory.appendingPathComponent("notes.txt")
        try Data("{}".utf8).write(to: first)
        try Data("{}".utf8).write(to: second)
        try Data("ignored".utf8).write(to: ignored)

        let source = try simulatorScenarioSource(
            runtimeConfig: SimulatorScenarioRuntimeConfig(
                enabledUntilEpochSeconds: Date().timeIntervalSince1970 + 60,
                filter: nil,
                baseURL: nil,
                handleA: nil,
                handleB: nil,
                deviceIDA: nil,
                deviceIDB: nil,
                controlCommandTransportPolicy: nil,
                scenarioFile: nil,
                scenarioDirectory: directory.path
            ),
            defaultDirectory: FileManager.default.temporaryDirectory
        )

        #expect(source.files == [second, first])
        #expect(source.description == directory.path)
    }

    @Test func hostedSimulatorScenariosUseResilientBackendTransport() throws {
        let config = simulatorScenarioBackendConfig(
            baseURL: try #require(URL(string: "https://beepbeep.to")),
            handle: "@avery",
            deviceID: "scenario-device"
        )

        #expect(config.httpTransport == .hostedSimulatorScenario)
    }

    @Test func localSimulatorScenariosKeepFailFastBackendTransport() throws {
        let config = simulatorScenarioBackendConfig(
            baseURL: try #require(URL(string: "http://localhost:8090/s/turbo")),
            handle: "@avery",
            deviceID: "scenario-device"
        )

        #expect(config.httpTransport == .failFastControlPlane)
    }

    @Test func simulatorScenariosCanForceHTTPOnlyControlCommandTransport() throws {
        let config = simulatorScenarioBackendConfig(
            baseURL: try #require(URL(string: "https://beepbeep.to")),
            handle: "@avery",
            deviceID: "scenario-device",
            controlCommandTransportPolicy: .httpOnly
        )

        #expect(config.controlCommandTransportPolicy == .httpOnly)
        #expect(config.httpTransport == .hostedSimulatorScenario)
    }

    @MainActor
    @Test func backendServicesSuppressesHTTPPresenceHeartbeatWhenWebSocketSessionIsConnected() {
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        let services = BackendServices(
            client: client,
            criticalHTTPClient: client.criticalHTTPClient,
            currentUserID: "user-self",
            mode: "cloud",
            telemetryEnabled: false
        )

        #expect(services.shouldSendHTTPPresenceHeartbeat == false)
    }

    @MainActor
    @Test func backendServicesUsesHTTPPresenceHeartbeatWhenWebSocketSessionIsMissing() {
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let services = BackendServices(
            client: client,
            criticalHTTPClient: client.criticalHTTPClient,
            currentUserID: "user-self",
            mode: "cloud",
            telemetryEnabled: false
        )

        #expect(services.shouldSendHTTPPresenceHeartbeat)
    }

    @MainActor
    @Test func backendServicesHTTPOnlyPolicyForcesHTTPPresenceHeartbeatFallback() {
        let client = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "test-device",
                controlCommandTransportPolicy: .httpOnly
            )
        )
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        let services = BackendServices(
            client: client,
            criticalHTTPClient: client.criticalHTTPClient,
            currentUserID: "user-self",
            mode: "cloud",
            telemetryEnabled: false
        )

        #expect(services.shouldSendHTTPPresenceHeartbeat)
    }

    @MainActor
    @Test func backendServicesUsesHTTPPresenceHeartbeatWhenWebSocketPresenceCommandsWereRejected() {
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        client.rejectWebSocketPresenceCommandsForTesting()
        let services = BackendServices(
            client: client,
            criticalHTTPClient: client.criticalHTTPClient,
            currentUserID: "user-self",
            mode: "cloud",
            telemetryEnabled: false
        )

        #expect(services.shouldSendHTTPPresenceHeartbeat)
    }

    @MainActor
    @Test func presenceHeartbeatUsesWebSocketIntervalWhenWebSocketSessionIsConnected() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        let services = BackendServices(
            client: client,
            criticalHTTPClient: client.criticalHTTPClient,
            currentUserID: "user-self",
            mode: "cloud",
            telemetryEnabled: false
        )

        #expect(viewModel.presenceHeartbeatMinimumInterval(backendServices: services) == 1.5)
    }

    @MainActor
    @Test func presenceHeartbeatUsesHTTPFallbackIntervalWhenWebSocketSessionIsMissing() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let services = BackendServices(
            client: client,
            criticalHTTPClient: client.criticalHTTPClient,
            currentUserID: "user-self",
            mode: "cloud",
            telemetryEnabled: false
        )

        #expect(viewModel.presenceHeartbeatMinimumInterval(backendServices: services) == 4)
    }

    @MainActor
    @Test func presenceHeartbeatCanDisableWebSocketInterval() {
        let viewModel = PTTViewModel()
        viewModel.presenceHeartbeatWebSocketIntervalSeconds = 0
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        let services = BackendServices(
            client: client,
            criticalHTTPClient: client.criticalHTTPClient,
            currentUserID: "user-self",
            mode: "cloud",
            telemetryEnabled: false
        )

        #expect(viewModel.presenceHeartbeatMinimumInterval(backendServices: services) == nil)
    }

    @MainActor
    @Test func hostedBackendClientWebSocketProbeStaysConnectedUnderHeartbeatAndTelemetryLoad() async throws {
        guard let runtime = hostedBackendClientProbeRuntime() else { return }

        let client = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: runtime.baseURL,
                devUserHandle: runtime.handle,
                deviceID: runtime.deviceID,
                httpTransport: simulatorScenarioBackendTransportConfig(baseURL: runtime.baseURL)
            )
        )

        var stateTransitions: [HostedBackendClientProbeTimedValue<String>] = []
        var serverNotices: [HostedBackendClientProbeTimedValue<String>] = []
        var statusNotices: [HostedBackendClientProbeTimedValue<HostedBackendClientProbeStatusNotice>] = []
        var auxiliaryRequests: [HostedBackendClientProbeHTTPMeasurement] = []
        let startedAt = Date()
        let startUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

        func elapsedMilliseconds() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds - startUptimeNanoseconds) / 1_000_000)
        }

        client.onWebSocketStateChange = { state in
            stateTransitions.append(
                HostedBackendClientProbeTimedValue(
                    elapsedMs: elapsedMilliseconds(),
                    value: String(describing: state)
                )
            )
        }
        client.onServerNotice = { message in
            serverNotices.append(
                HostedBackendClientProbeTimedValue(
                    elapsedMs: elapsedMilliseconds(),
                    value: message
                )
            )
        }
        client.onWebSocketStatusNotice = { notice in
            statusNotices.append(
                HostedBackendClientProbeTimedValue(
                    elapsedMs: elapsedMilliseconds(),
                    value: HostedBackendClientProbeStatusNotice(notice)
                )
            )
        }

        var runtimeConfigSummary = HostedBackendClientProbeRuntimeConfigSummary()
        var authHandle = runtime.handle
        var authUserID = ""
        var probeFailureSummary: String?
        defer {
            client.disconnectWebSocket()
            let artifact = HostedBackendClientProbeArtifact(
                startedAt: hostedBackendClientProbeISO8601Formatter.string(from: startedAt),
                baseURL: runtime.baseURL.absoluteString,
                handle: runtime.handle,
                deviceID: runtime.deviceID,
                durationSeconds: runtime.durationSeconds,
                heartbeatIntervalSeconds: runtime.heartbeatIntervalSeconds,
                telemetryIntervalSeconds: runtime.telemetryIntervalSeconds,
                runtimeConfig: runtimeConfigSummary,
                authenticatedHandle: authHandle,
                authenticatedUserID: authUserID,
                stateTransitions: stateTransitions,
                serverNotices: serverNotices,
                statusNotices: statusNotices,
                auxiliaryRequests: auxiliaryRequests,
                failureSummary: probeFailureSummary
            )
            try? writeHostedBackendClientProbeArtifact(artifact, to: runtime.artifactURL)
        }

        do {
            let runtimeConfig = try await client.fetchRuntimeConfig()
            runtimeConfigSummary = HostedBackendClientProbeRuntimeConfigSummary(runtimeConfig)
            #expect(runtimeConfig.supportsWebSocket)

            let session = try await client.authenticate()
            authHandle = session.handle
            authUserID = session.userId

            _ = try await client.registerDevice(
                label: "Hosted Backend Client Probe",
                alertPushToken: nil,
                alertPushEnvironment: nil
            )

            try await recordHostedBackendClientProbeRequest(
                name: "presence/keepalive:initial",
                into: &auxiliaryRequests
            ) {
                _ = try await client.heartbeatPresence()
            }

            client.connectWebSocket()

            try await waitForCondition(
                "hosted backend client websocket connected",
                timeoutNanoseconds: 15_000_000_000,
                pollNanoseconds: 100_000_000
            ) {
                client.isWebSocketConnected
            }

            if runtimeConfig.supportsSignalSessionIds {
                try await waitForCondition(
                    "hosted backend client websocket session notice",
                    timeoutNanoseconds: 15_000_000_000,
                    pollNanoseconds: 100_000_000
                ) {
                    client.webSocketSessionID != nil
                }
            }

            let loopStartedAt = DispatchTime.now().uptimeNanoseconds
            var nextHeartbeatAt = loopStartedAt + runtime.heartbeatIntervalNanoseconds
            var nextTelemetryAt = loopStartedAt + runtime.telemetryIntervalNanoseconds

            while DispatchTime.now().uptimeNanoseconds - loopStartedAt < runtime.durationNanoseconds {
                let now = DispatchTime.now().uptimeNanoseconds

                if runtime.heartbeatIntervalNanoseconds > 0, now >= nextHeartbeatAt {
                    try await recordHostedBackendClientProbeRequest(
                        name: "presence/keepalive",
                        into: &auxiliaryRequests
                    ) {
                        _ = try await client.heartbeatPresence()
                    }
                    nextHeartbeatAt += runtime.heartbeatIntervalNanoseconds
                    continue
                }

                if runtime.telemetryIntervalNanoseconds > 0, now >= nextTelemetryAt {
                    try await recordHostedBackendClientProbeRequest(
                        name: "telemetry/events",
                        into: &auxiliaryRequests
                    ) {
                        _ = try await client.uploadTelemetry(
                            TurboTelemetryEventRequest(
                                eventName: "hosted_backend_client_probe",
                                source: "turbo-tests",
                                severity: TurboTelemetrySeverity.notice.rawValue,
                                userId: authUserID,
                                userHandle: authHandle,
                                deviceId: runtime.deviceID,
                                sessionId: client.webSocketSessionID,
                                message: "Hosted backend client websocket continuity probe",
                                metadata: [
                                    "baseURL": runtime.baseURL.absoluteString,
                                    "elapsedMs": String(elapsedMilliseconds())
                                ],
                                devTraffic: true
                            )
                        )
                    }
                    nextTelemetryAt += runtime.telemetryIntervalNanoseconds
                    continue
                }

                let nextWakeAt = min(
                    nextHeartbeatAt > now ? nextHeartbeatAt : now + 250_000_000,
                    nextTelemetryAt > now ? nextTelemetryAt : now + 250_000_000
                )
                try await Task.sleep(
                    nanoseconds: min(250_000_000, max(10_000_000, nextWakeAt - now))
                )
            }

            let connectedTransitionIndex = stateTransitions.firstIndex { $0.value == "connected" }
            let idleAfterConnect = connectedTransitionIndex.map {
                stateTransitions.dropFirst($0 + 1).contains { $0.value == "idle" }
            } ?? true
            let reconnectNoticeFragments = [
                "WebSocket disconnected",
                "WebSocket connect timed out",
                "WebSocket ping failed",
                "WebSocket command failed; using HTTP fallback"
            ]
            let reconnectNotices = serverNotices.filter { timedValue in
                reconnectNoticeFragments.contains { timedValue.value.contains($0) }
            }
            let allAuxiliaryRequestsSucceeded = auxiliaryRequests.allSatisfy { $0.succeeded }

            #expect(stateTransitions.contains { $0.value == "connected" })
            #expect(!idleAfterConnect)
            #expect(reconnectNotices.isEmpty)
            #expect(allAuxiliaryRequestsSucceeded)

            _ = try? await client.offlinePresence()
        } catch {
            probeFailureSummary = error.localizedDescription
            throw error
        }
    }

    @Test func transportFaultRuntimeConsumesHTTPAndSignalRulesDeterministically() {
        let faults = TransportFaultRuntimeState()

        faults.setHTTPDelay(route: .contactSummaries, milliseconds: 250, count: 2)
        #expect(faults.consumeHTTPDelay(for: .contactSummaries) == 250)
        #expect(faults.consumeHTTPDelay(for: .contactSummaries) == 250)
        #expect(faults.consumeHTTPDelay(for: .contactSummaries) == 0)

        faults.setWebSocketSignalDelay(kind: .transmitStart, milliseconds: 400, count: 1)
        faults.duplicateNextWebSocketSignals(kind: .transmitStart, count: 1)
        faults.dropNextWebSocketSignals(kind: .transmitStop, count: 1)
        faults.reorderNextWebSocketSignals(kind: nil, count: 2)

        let startEnvelope = TurboSignalEnvelope(
            type: .transmitStart,
            channelId: "channel",
            fromUserId: "a",
            fromDeviceId: "device-a",
            toUserId: "b",
            toDeviceId: "device-b",
            payload: "{}"
        )
        let stopEnvelope = TurboSignalEnvelope(
            type: .transmitStop,
            channelId: "channel",
            fromUserId: "a",
            fromDeviceId: "device-a",
            toUserId: "b",
            toDeviceId: "device-b",
            payload: "{}"
        )

        switch faults.consumeWebSocketReorderResult(for: startEnvelope) {
        case .buffered:
            break
        case .deliver:
            Issue.record("Expected first reordered websocket signal to be buffered")
        }

        switch faults.consumeWebSocketReorderResult(for: stopEnvelope) {
        case .buffered:
            Issue.record("Expected reordered websocket fault to flush on the second signal")
        case .deliver(let envelopes):
            #expect(envelopes.map(\.type.rawValue) == ["transmit-stop", "transmit-start"])
        }

        let firstTransmitStartPlan = faults.consumeWebSocketSignalDeliveryPlan(for: .transmitStart)
        #expect(firstTransmitStartPlan.delayMilliseconds == 400)
        #expect(firstTransmitStartPlan.duplicateDeliveries == 1)
        #expect(firstTransmitStartPlan.shouldDrop == false)

        let secondTransmitStartPlan = faults.consumeWebSocketSignalDeliveryPlan(for: .transmitStart)
        #expect(secondTransmitStartPlan.delayMilliseconds == 0)
        #expect(secondTransmitStartPlan.duplicateDeliveries == 0)
        #expect(secondTransmitStartPlan.shouldDrop == false)

        let transmitStopPlan = faults.consumeWebSocketSignalDeliveryPlan(for: .transmitStop)
        #expect(transmitStopPlan.delayMilliseconds == 0)
        #expect(transmitStopPlan.duplicateDeliveries == 0)
        #expect(transmitStopPlan.shouldDrop == true)
    }

    @Test func conversationProjectionProperties() throws {
        try runProperty(
            PropertyRunConfig(seed: 0xC0FFEE, iterations: 240),
            name: "conversationProjectionProperties"
        ) { rng, iteration, seed in
            let sample = ConversationProjectionPropertySample.generate(rng: &rng)
            let projection = ConversationStateMachine.projection(
                for: sample.context,
                relationship: sample.relationship
            )
            let selectedConversationState = ConversationStateMachine.selectedConversationState(
                for: sample.context,
                relationship: sample.relationship
            )
            let reconciliationAction = ConversationStateMachine.reconciliationAction(for: sample.context)
            let observed = ConversationProjectionObserved(projection: projection)

            try requireProperty(
                projection.selectedConversationState == selectedConversationState,
                seed: seed,
                iteration: iteration,
                inputSummary: sample.summary,
                expectedInvariant: "projection.selectedConversationState must match selectedConversationState(for:relationship:)",
                observed: observed.summary
            )
            try requireProperty(
                projection.reconciliationAction == reconciliationAction,
                seed: seed,
                iteration: iteration,
                inputSummary: sample.summary,
                expectedInvariant: "projection.reconciliationAction must match reconciliationAction(for:)",
                observed: observed.summary
            )
            try requireProperty(
                projection.selectedConversationState.detail.phase == projection.selectedConversationState.phase,
                seed: seed,
                iteration: iteration,
                inputSummary: sample.summary,
                expectedInvariant: "selected Conversation detail and phase stay aligned",
                observed: observed.summary
            )
            try requireProperty(
                !projection.selectedConversationState.canTransmitNow || projection.selectedConversationState.phase == .ready,
                seed: seed,
                iteration: iteration,
                inputSummary: sample.summary,
                expectedInvariant: "canTransmitNow only appears on the ready projection",
                observed: observed.summary
            )
            let holdToTalkException =
                projection.selectedConversationState.phase == .wakeReady
                || projection.selectedConversationState.phase == .startingTransmit
                || projection.selectedConversationState.phase == .transmitting
            try requireProperty(
                !projection.selectedConversationState.allowsHoldToTalk
                    || projection.selectedConversationState.canTransmitNow
                    || holdToTalkException,
                seed: seed,
                iteration: iteration,
                inputSummary: sample.summary,
                expectedInvariant: "hold-to-talk affordance requires transmit capability, wake capability, or active transmit intent",
                observed: observed.summary
            )
            if sample.context.selectedContactID != sample.context.contactID {
                try requireProperty(
                    projection.reconciliationAction == .none,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: sample.summary,
                    expectedInvariant: "unselected contacts never emit selected Conversation reconciliation",
                    observed: observed.summary
                )
            }
            if case .leave(.reconciledTeardown(let contactID)) = sample.context.pendingAction,
               contactID == sample.context.contactID {
                try requireProperty(
                    projection.reconciliationAction == .none,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: sample.summary,
                    expectedInvariant: "queued reconciled teardown suppresses duplicate reconciliation",
                    observed: observed.summary
                )
            }
        }
    }

    @Test func pttReadinessAdapterFuzz() throws {
        try runProperty(
            PropertyRunConfig(seed: 424_242, iterations: 500),
            name: "pttReadinessAdapterFuzz"
        ) { rng, iteration, seed in
            let sample = PTTReadinessAdapterPropertySample.generate(rng: &rng)
            let unexpectedViolations = sample.relevantInvariantIDs

            try requireProperty(
                unexpectedViolations.isEmpty,
                seed: seed,
                iteration: iteration,
                inputSummary: sample.summary,
                expectedInvariant: "single-agent adapter evidence must derive a PTT-safe selected projection",
                observed: sample.observedSummary(violations: unexpectedViolations)
            )

            let holdToTalkException =
                sample.selectedConversationState.phase == .wakeReady
                || sample.selectedConversationState.phase == .startingTransmit
                || sample.selectedConversationState.phase == .transmitting
            try requireProperty(
                !sample.selectedConversationState.allowsHoldToTalk
                    || sample.selectedConversationState.canTransmitNow
                    || holdToTalkException,
                seed: seed,
                iteration: iteration,
                inputSummary: sample.summary,
                expectedInvariant: "hold-to-talk is enabled only by transmit capability, wake, or active transmit intent",
                observed: sample.observedSummary(violations: unexpectedViolations)
            )

            if sample.pendingLeaveInFlight {
                try requireProperty(
                    !sample.selectedConversationState.canTransmitNow
                        && !sample.selectedConversationState.allowsHoldToTalk
                        && sample.reconciliationAction != .restoreDevicePTTSession(contactID: sample.context.contactID),
                    seed: seed,
                    iteration: iteration,
                    inputSummary: sample.summary,
                    expectedInvariant: "pending leave fail-closes hold-to-talk and automatic restore",
                    observed: sample.observedSummary(violations: unexpectedViolations)
                )
            }

            if sample.controlPlaneReconnectGraceActive {
                try requireProperty(
                    !sample.selectedConversationState.canTransmitNow
                        && !(sample.selectedConversationState.phase == .ready && sample.selectedConversationState.allowsHoldToTalk),
                    seed: seed,
                    iteration: iteration,
                    inputSummary: sample.summary,
                    expectedInvariant: "control-plane reconnect grace disables normal hold-to-talk",
                    observed: sample.observedSummary(violations: unexpectedViolations)
                )
            }

            if sample.remoteTransmitStopObserved,
               !sample.remoteTransmitStopProjectionGraceActive {
                try requireProperty(
                    sample.selectedConversationState.phase != .receiving,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: sample.summary,
                    expectedInvariant: "remote transmit stop clears receiving projection once playback grace is gone",
                    observed: sample.observedSummary(violations: unexpectedViolations)
                )
            }
        }
    }

    @Test func pttReadinessStaleBackendFaultHarness() throws {
        try runProperty(
            PropertyRunConfig(seed: 0xBAD5EED, iterations: 320),
            name: "pttReadinessStaleBackendFaultHarness"
        ) { rng, iteration, seed in
            let sample = PTTReadinessAdapterPropertySample.generateStaleBackendFault(rng: &rng)

            try requireProperty(
                !sample.selectedConversationState.canTransmitNow
                    && !sample.selectedConversationState.allowsHoldToTalk,
                seed: seed,
                iteration: iteration,
                inputSummary: sample.summary,
                expectedInvariant: "adversarial stale backend/session evidence never enables hold-to-talk",
                observed: sample.observedSummary(violations: sample.staleBackendInvariantIDs)
            )

            if sample.pendingLeaveInFlight || sample.restoreBarrierActive {
                try requireProperty(
                    sample.reconciliationAction != .restoreDevicePTTSession(contactID: sample.context.contactID),
                    seed: seed,
                    iteration: iteration,
                    inputSummary: sample.summary,
                    expectedInvariant: "pending leave or recent leave barrier prevents automatic local-session restore",
                    observed: sample.observedSummary(violations: sample.staleBackendInvariantIDs)
                )
            }

            if sample.backendMembershipStaleWithoutLocalEvidence {
                try requireProperty(
                    sample.reconciliationAction == .clearStaleBackendMembership(contactID: sample.context.contactID)
                        || sample.staleBackendInvariantIDs.contains("selected.stale_backend_membership_without_local_device_ptt_evidence")
                        || sample.staleBackendInvariantIDs.contains("selected.stale_membership_friend_ready_without_local_device_ptt_evidence"),
                    seed: seed,
                    iteration: iteration,
                    inputSummary: sample.summary,
                    expectedInvariant: "stale durable backend membership is either repaired or surfaced as a stale-membership contract",
                    observed: sample.observedSummary(violations: sample.staleBackendInvariantIDs)
                )
            }
        }
    }

    @Test func backendReadyWithoutAppleSessionNeverEnablesHoldToTalk() {
        let sample = PTTReadinessAdapterPropertySample.make(
            actions: ["backendReady", "mediaReady"],
            localSessionMode: .none,
            backendMode: .bothReady(peerDeviceConnected: true, canTransmit: true),
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            firstTalkStartupProfile: .relayWarm
        )

        #expect(!sample.selectedConversationState.canTransmitNow)
        #expect(!sample.selectedConversationState.allowsHoldToTalk)
        #expect(!sample.relevantInvariantIDs.contains("selected.hold_to_talk_requires_transmit_capability"))
    }

    @Test func wakeReadyRequiresActiveAppleSessionAndWakeCapableReceiver() {
        let sample = PTTReadinessAdapterPropertySample.make(
            actions: ["appleAligned", "backendWaitingForPeer", "receiverWakeCapable", "mediaReady"],
            localSessionMode: .aligned,
            backendMode: .bothWaitingForPeer(peerDeviceConnected: false),
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            hadConnectedDevicePTTContinuity: true,
            firstTalkStartupProfile: .relayWarm
        )

        #expect(sample.selectedConversationState.phase == .wakeReady)
        #expect(sample.selectedConversationState.allowsHoldToTalk)
        #expect(!sample.relevantInvariantIDs.contains("selected.wake_ready_requires_aligned_apple_session"))
    }

    @Test func reconnectGraceDisablesNormalHoldToTalk() {
        let sample = PTTReadinessAdapterPropertySample.make(
            actions: ["appleAligned", "backendReady", "enterReconnectGrace", "mediaReady"],
            localSessionMode: .aligned,
            backendMode: .bothReady(peerDeviceConnected: true, canTransmit: true),
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .unavailable,
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            backendConvergence: BackendConversationConvergenceState(
                joinPhase: .stable,
                controlPlaneContinuity: .reconnectGrace
            ),
            firstTalkStartupProfile: .relayWarm
        )

        #expect(!sample.selectedConversationState.canTransmitNow)
        #expect(!sample.selectedConversationState.allowsHoldToTalk)
        #expect(!sample.relevantInvariantIDs.contains("selected.control_plane_reconnect_grace_disables_hold_to_talk"))
    }

    @Test func pendingLeaveStaleBackendReadyDoesNotEnableHoldToTalkOrRestoreSession() {
        let sample = PTTReadinessAdapterPropertySample.make(
            actions: ["appleAligned", "pendingExplicitLeave", "staleBackendReady"],
            localSessionMode: .aligned,
            backendMode: .bothReady(peerDeviceConnected: true, canTransmit: true),
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
            pendingAction: .leave(.explicit(contactID: nil)),
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            firstTalkStartupProfile: .relayWarm
        )

        #expect(sample.pendingLeaveInFlight)
        #expect(!sample.selectedConversationState.canTransmitNow)
        #expect(!sample.selectedConversationState.allowsHoldToTalk)
        #expect(sample.reconciliationAction == .none)
    }

    @Test func recentLeaveBarrierPreventsStaleBackendReadyAutoRestore() {
        let contactID = UUID()
        let channelUUID = UUID()
        let sample = PTTReadinessAdapterPropertySample.make(
            actions: ["appleNone", "recentLeaveBarrier", "staleBackendReady"],
            contactID: contactID,
            channelUUID: channelUUID,
            localSessionMode: .none,
            backendMode: .bothReady(peerDeviceConnected: true, canTransmit: true),
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
            devicePTTRestoreBarrier: .recentSystemLeave(
                contactID: contactID,
                channelUUID: channelUUID,
                reason: "test"
            ),
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            firstTalkStartupProfile: .relayWarm
        )

        #expect(sample.restoreBarrierActive)
        #expect(!sample.selectedConversationState.canTransmitNow)
        #expect(!sample.selectedConversationState.allowsHoldToTalk)
        #expect(sample.reconciliationAction != .restoreDevicePTTSession(contactID: contactID))
    }

    @Test func staleInactiveBackendMembershipWithoutDevicePTTEvidenceIsContractedAndNotHoldToTalk() {
        let sample = PTTReadinessAdapterPropertySample.make(
            actions: ["appleNone", "backendBothInactiveStale"],
            localSessionMode: .none,
            backendMode: .bothInactiveStale,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .unavailable,
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            firstTalkStartupProfile: .relayWarm
        )

        #expect(!sample.selectedConversationState.canTransmitNow)
        #expect(!sample.selectedConversationState.allowsHoldToTalk)
        #expect(
            sample.staleBackendInvariantIDs.contains(
                "selected.stale_backend_membership_without_local_device_ptt_evidence"
            )
        )
    }

    @Test func backendLocalTransmitObservationBeforeAppleBeginDoesNotStartCaptureAtAppBoundary() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-a-b",
            remoteUserId: "peer-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, peerTargetDeviceId: "peer-device")
            )
        )
        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "test")

        let transition = viewModel.receiveEngineEvent(
            .backend(.localTransmitObserved("tx-backend")),
            source: "test-local-transmit-observed"
        )

        #expect(
            !transition.effects.contains {
                if case .media(.startCapture) = $0 { return true }
                return false
            }
        )
        if case .beginning(let attempt) = transition.state.transmit {
            #expect(attempt.backendTransmitID == "tx-backend")
            #expect(attempt.systemTransmitID == nil)
        } else {
            Issue.record("expected backend observation to create a beginning transmit attempt")
        }
    }

    @Test func remoteTransmitStopClearsReceivingProjectionAfterPlaybackDrain() {
        let sample = PTTReadinessAdapterPropertySample.make(
            actions: ["appleAligned", "remoteStart", "remoteStop", "playbackDrainEnd"],
            localSessionMode: .aligned,
            backendMode: .peerTransmitting,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .unavailable,
            remoteParticipantSignalIsTransmitting: true,
            remotePlaybackContinuity: .stopped(projectionGraceActive: false),
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            firstTalkStartupProfile: .relayWarm
        )

        #expect(sample.selectedConversationState.phase != .receiving)
        #expect(!sample.relevantInvariantIDs.contains("selected.receiving_after_remote_transmit_stop"))
    }

    @Test func transportFaultPlannerProperties() throws {
        try runProperty(
            PropertyRunConfig(seed: 0xF00DCAFE, iterations: 180),
            name: "transportFaultPlannerProperties"
        ) { rng, iteration, seed in
            let actions = SimulatorScenarioActionPropertySample.generateActions(rng: &rng)
            let scheduled = try scheduledScenarioActions(for: actions)
            let expectedCount = actions.reduce(0) { partial, action in
                partial + ((action.drop ?? false) ? 0 : (action.repeatCount ?? 1))
            }
            let delays = scheduled.map(\.scheduledDelayMilliseconds)
            let observed = "scheduledCount=\(scheduled.count) delays=\(delays) actions=\(actions.map(\.type))"

            try requireProperty(
                scheduled.count == expectedCount,
                seed: seed,
                iteration: iteration,
                inputSummary: SimulatorScenarioActionPropertySample.summary(actions),
                expectedInvariant: "scheduled action count equals non-dropped repeat deliveries",
                observed: observed
            )
            try requireProperty(
                delays == delays.sorted(),
                seed: seed,
                iteration: iteration,
                inputSummary: SimulatorScenarioActionPropertySample.summary(actions),
                expectedInvariant: "scheduled actions are monotonic by delivery time",
                observed: observed
            )

            let faults = TransportFaultRuntimeState()
            let route = rng.pick(TransportFaultHTTPRoute.allCases)
            let delay = rng.nextInt(in: 0...1_500)
            let count = rng.nextInt(in: 1...5)
            faults.setHTTPDelay(route: route, milliseconds: delay, count: count)
            let consumedDelays = (0..<(count + 2)).map { _ in faults.consumeHTTPDelay(for: route) }
            try requireProperty(
                consumedDelays == Array(repeating: delay, count: count) + [0, 0],
                seed: seed,
                iteration: iteration,
                inputSummary: "route=\(route.rawValue) delay=\(delay) count=\(count)",
                expectedInvariant: "HTTP delay rules are consumed exactly count times",
                observed: "consumedDelays=\(consumedDelays)"
            )

            let signalKind = rng.pick(SimulatorScenarioActionPropertySample.signalKinds)
            let dropCount = rng.nextInt(in: 1...4)
            faults.dropNextWebSocketSignals(kind: signalKind, count: dropCount)
            let deliveryPlans = (0..<(dropCount + 2)).map { _ in
                faults.consumeWebSocketSignalDeliveryPlan(for: signalKind)
            }
            try requireProperty(
                deliveryPlans.prefix(dropCount).allSatisfy(\.shouldDrop)
                    && deliveryPlans.dropFirst(dropCount).allSatisfy { !$0.shouldDrop },
                seed: seed,
                iteration: iteration,
                inputSummary: "signalKind=\(signalKind.rawValue) dropCount=\(dropCount)",
                expectedInvariant: "websocket drop rules are consumed exactly count times",
                observed: "plans=\(deliveryPlans)"
            )
        }
    }
}
