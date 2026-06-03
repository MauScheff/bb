//
//  PTTViewModel.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import Observation
import TurboEngine
import PushToTalk
import AVFAudio
import Network
import UIKit
import UserNotifications

private final class BackgroundActivityLease {
    var identifier: UIBackgroundTaskIdentifier = .invalid
    var ended = false
}

enum AudioOutputPreference: String, Equatable {
    case speaker
    case phone

    static let storageKey = "turbo.audioOutputPreference"

    static func loadStored() -> AudioOutputPreference {
        .speaker
    }

    var next: AudioOutputPreference {
        switch self {
        case .speaker:
            return .phone
        case .phone:
            return .speaker
        }
    }

    var buttonLabel: String {
        switch self {
        case .speaker:
            return "Speaker"
        case .phone:
            return "Phone"
        }
    }
}

struct AudioOutputRouteOverridePlan: Equatable {
    enum Action: Equatable {
        case none
        case speaker
        case clearSpeakerOverride
    }

    let action: Action

    var shouldApplySpeakerOverride: Bool {
        action == .speaker
    }

    var shouldClearSpeakerOverride: Bool {
        action == .clearSpeakerOverride
    }

    static func forCurrentRoute(
        preference: AudioOutputPreference,
        category: AVAudioSession.Category,
        outputPortTypes: [AVAudioSession.Port]
    ) -> AudioOutputRouteOverridePlan {
        guard category == .playAndRecord else {
            return AudioOutputRouteOverridePlan(action: .none)
        }

        if outputPortTypes.contains(where: \.isExternalAudioOutput) {
            return AudioOutputRouteOverridePlan(action: .none)
        }

        switch preference {
        case .speaker:
            guard outputPortTypes.contains(.builtInReceiver) else {
                return AudioOutputRouteOverridePlan(action: .none)
            }

            let speakerAlreadyActive = outputPortTypes.contains(.builtInSpeaker)
            return AudioOutputRouteOverridePlan(
                action: speakerAlreadyActive ? .none : .speaker
            )
        case .phone:
            guard outputPortTypes.contains(.builtInSpeaker) else {
                return AudioOutputRouteOverridePlan(action: .none)
            }
            return AudioOutputRouteOverridePlan(action: .clearSpeakerOverride)
        }
    }
}

private extension AVAudioSession.Port {
    var isExternalAudioOutput: Bool {
        self == .bluetoothA2DP
            || self == .bluetoothHFP
            || self == .bluetoothLE
            || self == .headphones
            || self == .usbAudio
            || self == .carAudio
            || self == .airPlay
            || self == .HDMI
            || self == .lineOut
    }
}

enum AutomaticDiagnosticsPublishDeferralReason: String, Equatable {
    case callScreen = "call-screen"
    case liveMedia = "live-media"

    var statusText: String {
        switch self {
        case .callScreen:
            return "Diagnostics waiting for call to end"
        case .liveMedia:
            return "Diagnostics waiting for audio to finish"
        }
    }
}

struct AutomaticDiagnosticsPublishDeferredError: Error, Equatable {
    let reason: AutomaticDiagnosticsPublishDeferralReason
}

@MainActor
@Observable
final class PTTViewModel: NSObject, MediaSessionDelegate {
    enum LifecyclePresenceTransitionKind {
        case activeSession
        case background
        case offline
    }

    static let shared = PTTViewModel(pttSystemPolicyDefaults: .standard)
    struct HostedBackendClientProbeBootstrapControl: Decodable {
        let enabledUntilEpochSeconds: TimeInterval
        let suppressSharedAppBackendBootstrap: Bool?
    }

    private static var isRunningAutomatedTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static let hostedBackendClientProbeRuntimeConfigURL = URL(
        fileURLWithPath: "/tmp/turbo-debug/hosted_backend_client_probe_runtime.json"
    )

    static var shouldSuppressSharedAppBackendBootstrapForAutomatedTests: Bool {
        guard isRunningAutomatedTests,
              let data = try? Data(contentsOf: hostedBackendClientProbeRuntimeConfigURL),
              let config = try? JSONDecoder().decode(
                  HostedBackendClientProbeBootstrapControl.self,
                  from: data
              ),
              Date().timeIntervalSince1970 <= config.enabledUntilEpochSeconds else {
            return false
        }

        return config.suppressSharedAppBackendBootstrap == true
    }

    private static func initialEngineLocalDeviceID() -> EngineDeviceID {
        EngineDeviceID(TurboBackendConfig.load()?.deviceID ?? "unconfigured")
    }

    var isReady: Bool {
        pttSystemClient.isReady
    }
    var isJoined: Bool {
        engine.snapshot.conversation.joinedEvidence != nil
    }
    var isTransmitting: Bool {
        if case .active = engine.snapshot.transmit { return true }
        return false
    }
    var statusMessage: String = "Initializing..."
    var pushTokenHex: String = ""
    var alertPushTokenHex: String = ""
    var contacts: [Contact] = []
    var selectedContactId: UUID?
    let diagnostics = DiagnosticsStore()
    var engine: TurboEngine
    var engineTraceRecorder: TurboEngineTraceRecorder
    var activeChannelId: UUID? {
        guard let joined = engine.snapshot.conversation.joinedEvidence else { return nil }
        return UUID(uuidString: joined.friend.contactID.rawValue)
    }

    let pttSystemClient: any PTTSystemClientProtocol
    @ObservationIgnored
    private let pttSystemPolicyDefaults: UserDefaults?
    let channelName: String = "BeepBeep Prototype"
    var conversationActionCoordinator = ConversationActionCoordinatorState()
    let backendSyncCoordinator = BackendSyncCoordinator()
    let controlPlaneCoordinator = ControlPlaneCoordinator()
    let receiveExecutionCoordinator = ReceiveExecutionCoordinator()
    let backendCommandCoordinator = BackendCommandCoordinator()
    let pttCoordinator = PTTCoordinator()
    let transmitCoordinator = TransmitCoordinator()
    let transmitTaskCoordinator = TransmitTaskCoordinator()
    let selectedConversationCoordinator = SelectedConversationCoordinator()
    let controlEventIngestor = ControlEventIngestor()
    let liveConversationActivityController = LiveConversationActivityController()
    let selfCheckCoordinator = DevSelfCheckCoordinator()
    let pttSystemPolicyCoordinator = PTTSystemPolicyCoordinator()
    var backendRuntime = BackendRuntimeState()
    var incomingBeepSurfaceState = IncomingBeepSurfaceState()
    var transmitRuntime = TransmitRuntimeState()
    var transmitStartupTiming = TransmitStartupTimingState()
    var transmitTaskRuntime = TransmitTaskRuntimeState()
    var pttWakeRuntime = PTTWakeRuntimeState()
    var receiveExecutionRuntime = ReceiveExecutionRuntimeState()
    var mediaRuntime = MediaRuntimeState()
    let incomingAudioIngressExecutor = IncomingAudioIngressExecutor()
    var backendConfigurationTask: Task<Void, Never>?
    var backendConfigurationKey: String?
    var backendConfigurationToken: UUID?
    var lastBackendBootstrapFailureMessage: String?
    var isPTTAudioSessionActive: Bool = false
    var localAudioLevel: Double = 0
    var backendBootstrapRetryDelayNanoseconds: UInt64 = 2_000_000_000
    var disconnectRecoveryDelayNanoseconds: UInt64 = 5_000_000_000
    var disconnectRecoveryRetryDelayNanoseconds: UInt64 = 2_000_000_000
    var disconnectRecoveryMaxWaitNanoseconds: UInt64 = 15_000_000_000
    var remoteAudioInitialChunkTimeoutNanoseconds: UInt64 = 5_000_000_000
    var remoteAudioForegroundInitialChunkTimeoutNanoseconds: UInt64 = 2_000_000_000
    var remoteAudioSilenceTimeoutNanoseconds: UInt64 = 1_500_000_000
    var remoteAudioPendingPlaybackDrainMaxNanoseconds: UInt64 = 5_000_000_000
    var remoteAudioNonAuthoritativePlaybackDrainMaxNanoseconds: UInt64 = 750_000_000
    var remoteAudioNonAuthoritativePlaybackDrainPollNanoseconds: UInt64 = 150_000_000
    var remoteAudioChunkContinuityGapNanoseconds: UInt64 = 350_000_000
    var directQuicIncomingAudioQueueSlowNanoseconds: UInt64 = 120_000_000
    var directQuicIncomingAudioQueueDelayViolationNanoseconds: UInt64 = 240_000_000
    var directQuicIncomingAudioLiveBacklogDropNanoseconds: UInt64 = 800_000_000
    var directQuicIncomingAudioQueueSevereDelayNanoseconds: UInt64 = 1_000_000_000
    var incomingLiveAudioBacklogExpirationNanoseconds: UInt64 = 2_000_000_000
    var remoteTransmitStopProjectionGraceNanoseconds: UInt64 = 8_000_000_000
    var localTransmitStopProjectionGraceNanoseconds: UInt64 = 3_000_000_000
    var firstAudioPlaybackAckTimeoutNanoseconds: UInt64 = 2_000_000_000
    var appleGatedAudioActivationTimeoutNanoseconds: UInt64 = 5_000_000_000
    var foregroundSystemReceivePlaybackFallbackDelayNanoseconds: UInt64 = 300_000_000
    var presenceHeartbeatHTTPFallbackIntervalSeconds: TimeInterval = 4
    var presenceHeartbeatWebSocketIntervalSeconds: TimeInterval = 1.5
    var foregroundAppManagedInteractiveAudioPrewarmEnabled = true
    var lastReportedPTTServiceStatus: PTServiceStatus?
    var lastReportedPTTServiceStatusChannelUUID: UUID?
    var lastReportedPTTServiceStatusReason: String?
    var lastReportedPTTTransmissionMode: PTTransmissionMode?
    var lastReportedPTTTransmissionModeChannelUUID: UUID?
    var lastReportedPTTTransmissionModeReason: String?
    var lastReportedPTTAccessoryButtonEventsChannelUUID: UUID?
    var lastReportedPTTAccessoryButtonEventsReason: String?
    var lastReportedPTTDescriptorName: String?
    var lastReportedPTTDescriptorChannelUUID: UUID?
    var lastReportedPTTDescriptorReason: String?
    @ObservationIgnored
    var systemActiveRemoteParticipantNameByChannelUUID: [UUID: String] = [:]
    var localOnlySystemLeaveSuppressions: [UUID: LocalOnlySystemLeaveSuppression] = [:]
    var staleSystemRejoinSuppressions: [UUID: StaleSystemRejoinSuppression] = [:]
    var systemTransmitBeginRecoveryAttemptsByChannelUUID: [UUID: Int] = [:]
    var pendingSystemTransmitRetryAfterRejoinByContactID: [UUID: UUID] = [:]
    var recentOutgoingJoinAcceptedTokensByContactID: [UUID: RecentOutgoingJoinAcceptedToken] = [:]
    var recentOutgoingBeepEvidenceByContactID: [UUID: RecentOutgoingBeepEvidence] = [:]
    var optimisticOutgoingBeepEvidenceByContactID: [UUID: OptimisticOutgoingBeepEvidence] = [:]
    var recentPeerDeviceEvidenceByContactID: [UUID: RecentPeerDeviceEvidence] = [:]
    var selectedContactPrewarmInFlight: Set<UUID> = []
    var selectedContactPrewarmedSelectionContactID: UUID?
    var selectedContactPrewarmPipelineEnabled: Bool = true
    var localTransmitStopProjectionGraceStartedAtNanosecondsByContactID: [UUID: UInt64] = [:]
    var localTransmitStopProjectionGraceStartedAtMillisecondsByContactID: [UUID: Int64] = [:]
    var firstAudioPlaybackAckExpectationsByContactID: [UUID: FirstAudioPlaybackAckExpectation] = [:]
    var firstAudioPlaybackAckTimeoutTasksByContactID: [UUID: Task<Void, Never>] = [:]
    var firstAudioPlaybackAckSentKeys: Set<FirstAudioPlaybackAckSentKey> = []
    var firstAudioPlaybackAckSentEncryptedSequenceByKey: [FirstAudioPlaybackAckSentKey: UInt64] = [:]
    var firstAudioPlaybackAckCompletedKeys: Set<FirstAudioPlaybackAckSentKey> = []
    var directAudioPlaybackVerifiedKeys: Set<FirstAudioPlaybackAckSentKey> = []
    var pendingBeginTransmitAfterSettlingTask: Task<Void, Never>?
    private var diagnosticsAutoPublishTask: Task<Void, Never>?
    private var diagnosticsAutoPublishPendingTrigger: String?
    private let diagnosticsAutoPublishDelayNanoseconds: UInt64 = 20_000_000_000
    var disconnectRecoveryTask: Task<Void, Never>?
    var automaticDiagnosticsPublishEnabled: Bool = false
    var automaticDiagnosticsPublishStatusText: String?
    var stateCaptureTelemetryEnabled: Bool = false
    var conversationShortcutPolicy: ConversationShortcutPolicy = .load()
    var microphonePermission: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    var hasLoadedNotificationAuthorizationStatus: Bool = false
    var localNetworkPreflightStatus: LocalNetworkPreflightStatus = .loadStored()
    var audioOutputPreference: AudioOutputPreference = .loadStored()
    var pendingBeepNotificationHandle: String?
    var pendingBeepNotificationShouldJoin: Bool = false
    var foregroundBeepNotificationPrewarmedBeepIDs: Set<String> = []
    let pendingForegroundBeepSurfaceLifetime: TimeInterval = 20
    var requestedExpandedCallContactID: UUID?
    var requestedExpandedCallSequence: Int = 0
    var uiProjectionDiagnostics: UIProjectionDiagnostics = .unknown
    var selectedConnectionAttemptTimeoutTask: Task<Void, Never>?
    var selectedConnectionAttemptTimeoutKey: String?
    var selectedConnectionAttemptTimeoutNanoseconds: UInt64 = 5_000_000_000
    var maxUnresolvedLocalJoinAttempts: Int = 2
    var deferredAbsentMembershipRecoveryNoticeKeys: Set<String> = []
    var liveCallControlPlaneReconnectGraceStartedAt: Date?
    var liveCallControlPlaneReconnectGraceSeconds: TimeInterval = 10
    var directQuicProvisioningStatus: String = "not-started"
    var directQuicRegisteredFingerprint: String?
    var directQuicIdentityRepairAttemptedDeviceIDs: Set<String> = []
    var pendingDirectQuicIdentityProvisioningFailureTelemetry: [String: String]?
    var mediaEncryptionProvisioningStatus: String = "not-started"
    var mediaEncryptionLocalIdentity: MediaEncryptionLocalIdentity?
    @ObservationIgnored
    let localNetworkPermissionPreflight = LocalNetworkPermissionPreflight()
    var applicationStateOverride: UIApplication.State?
    @ObservationIgnored
    var backgroundOfflinePresenceHandler: (@MainActor () async -> Void)?
    @ObservationIgnored
    var backgroundActiveSessionPresenceHandler: (@MainActor () async -> Void)?
    @ObservationIgnored
    var backgroundSessionPresenceHandler: (@MainActor () async -> Void)?
    @ObservationIgnored
    var backgroundWebSocketSuspendHandler: (@MainActor () -> Void)?
    @ObservationIgnored
    var lastLifecyclePresenceTransitionKind: LifecyclePresenceTransitionKind?
    @ObservationIgnored
    var lastLifecyclePresenceTransitionAt: Date?
    @ObservationIgnored
    var lifecyclePresenceTransitionInFlightKind: LifecyclePresenceTransitionKind?
    var lifecyclePresenceTransitionDeduplicationWindowSeconds: TimeInterval = 2
    @ObservationIgnored
    var beginBackgroundActivity: @MainActor (String, @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier = { name, expiration in
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }
    @ObservationIgnored
    var endBackgroundActivity: @MainActor (UIBackgroundTaskIdentifier) -> Void = { identifier in
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
    @ObservationIgnored
    var setApplicationBadgeCount: @MainActor (Int) -> Void = { count in
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
    @ObservationIgnored
    var clearDeliveredNotifications: @MainActor () -> Void = {
        TurboNotificationCategory.clearDeliveredBeepNotifications()
    }
    @ObservationIgnored
    var conversationParticipantTelemetryNetworkMonitor: NWPathMonitor?
    @ObservationIgnored
    let conversationParticipantTelemetryNetworkQueue = DispatchQueue(label: "Turbo.ConversationParticipantTelemetryNetworkMonitor")
    @ObservationIgnored
    var conversationParticipantTelemetryPollTask: Task<Void, Never>?
    @ObservationIgnored
    var conversationParticipantTelemetryOutputVolumeObservation: NSKeyValueObservation?
    @ObservationIgnored
    var proximityMonitoringIsActive = false
    @ObservationIgnored
    var isPhoneNearEar = false
    @ObservationIgnored
    var automaticAudioRouteBasePreference: AudioOutputPreference?
    @ObservationIgnored
    var automaticAudioRouteSwitchingEnabled = true
    @ObservationIgnored
    var mediaRelayConnectOverride: (@MainActor (
        TurboMediaRelayClient,
        TurboMediaRelayClientConfig,
        UUID,
        String,
        String,
        String
    ) async throws -> TurboMediaRelayTransport)?
    @ObservationIgnored
    var mediaRelayQuicUpgradeOverride: (@MainActor (
        TurboMediaRelayClient,
        UUID,
        String,
        String,
        String
    ) async throws -> TurboMediaRelayTransport)?
    @ObservationIgnored
    var mediaRelayReceiverPrewarmSendOverride: (@MainActor (
        TurboMediaRelayClient,
        DirectQuicReceiverPrewarmPayload
    ) async throws -> Void)?
    @ObservationIgnored
    var mediaRelayAudioSendOverride: (@MainActor (
        TurboMediaRelayClient,
        String
    ) async throws -> TurboMediaRelayMediaMode)?
    @ObservationIgnored
    var directQuicAudioSendOverride: (@MainActor (
        DirectQuicProbeController,
        String
    ) async throws -> Void)?

    var localConversationNetworkInterface: ConversationNetworkInterface = .unknown
    var localConversationParticipantTelemetry: ConversationParticipantTelemetry?
    var lastPublishedConversationParticipantTelemetryByContactID: [UUID: ConversationParticipantTelemetry] = [:]
    var lastPublishedConversationParticipantTelemetryAtByContactID: [UUID: Date] = [:]
    var conversationParticipantTelemetryByContactID: [UUID: ConversationParticipantTelemetry] = [:]

#if DEBUG
    private static var automaticDiagnosticsPublishDefaultEnabled: Bool {
        ProcessInfo.processInfo.environment["TURBO_IOS_AUTOMATIC_DIAGNOSTICS_PUBLISH"] != "0"
    }

    private static var reducerTransitionDiagnosticsEnabled: Bool {
        Self.isRunningAutomatedTests
            || ProcessInfo.processInfo.environment["TURBO_IOS_REDUCER_TRANSITION_DIAGNOSTICS"] == "1"
    }

    private static var selectedContactPrewarmPipelineDefaultEnabled: Bool {
        ProcessInfo.processInfo.environment["TURBO_IOS_SELECTED_CONTACT_PREWARM"] != "0"
    }
#endif

    var localReceiverAudioReadinessPublications: [UUID: ReceiverAudioReadinessPublication] {
        get { controlPlaneCoordinator.state.localReceiverAudioReadinessPublications }
        set { controlPlaneCoordinator.replaceLocalReceiverAudioReadinessPublications(newValue) }
    }

    var remoteTransmittingContactIDs: Set<UUID> {
        get { receiveExecutionCoordinator.state.remoteTransmittingContactIDs }
        set { receiveExecutionCoordinator.replaceRemoteTransmittingContactIDs(newValue) }
    }

    var remoteAudioSilenceTasks: [UUID: Task<Void, Never>] {
        get { receiveExecutionRuntime.remoteAudioSilenceTasks }
        set { receiveExecutionRuntime.replaceRemoteAudioSilenceTasks(newValue) }
    }

    init(
        pttSystemClient: (any PTTSystemClientProtocol)? = nil,
        pttSystemPolicyDefaults: UserDefaults? = nil
    ) {
        let initialEngineLocalDeviceID = Self.initialEngineLocalDeviceID()
        self.engine = TurboEngine(localDeviceID: initialEngineLocalDeviceID)
        self.engineTraceRecorder = TurboEngineTraceRecorder(localDeviceID: initialEngineLocalDeviceID)
        self.pttSystemClient = pttSystemClient ?? makeDefaultPTTSystemClient()
        self.pttSystemPolicyDefaults = pttSystemPolicyDefaults
        audioOutputPreference = .speaker
        UserDefaults.standard.set(AudioOutputPreference.speaker.rawValue, forKey: AudioOutputPreference.storageKey)
#if DEBUG
        automaticDiagnosticsPublishEnabled =
            Self.automaticDiagnosticsPublishDefaultEnabled && !Self.isRunningAutomatedTests
        stateCaptureTelemetryEnabled =
            ProcessInfo.processInfo.environment["TURBO_IOS_STATE_CAPTURE_TELEMETRY"] == "1"
        selectedContactPrewarmPipelineEnabled =
            Self.selectedContactPrewarmPipelineDefaultEnabled && !Self.isRunningAutomatedTests
#endif
        super.init()
        diagnostics.onHighSignalEvent = { [weak self] event in
            self?.handleHighSignalDiagnosticsEvent(event)
        }
#if DEBUG
        if Self.reducerTransitionDiagnosticsEnabled {
            let recordReducerTransition: @MainActor (ReducerTransitionReport) -> Void = { [weak self] report in
                self?.diagnostics.recordReducerTransition(report)
            }
            selectedConversationCoordinator.transitionReporter = recordReducerTransition
            backendSyncCoordinator.transitionReporter = recordReducerTransition
            controlPlaneCoordinator.transitionReporter = recordReducerTransition
            receiveExecutionCoordinator.transitionReporter = recordReducerTransition
            backendCommandCoordinator.transitionReporter = recordReducerTransition
            pttCoordinator.transitionReporter = recordReducerTransition
            transmitCoordinator.transitionReporter = recordReducerTransition
            transmitTaskCoordinator.transitionReporter = recordReducerTransition
            controlEventIngestor.transitionReporter = recordReducerTransition
        }
#endif
        selectedConversationCoordinator.effectHandler = { [weak self] effect in
            await self?.runSelectedConversationEffect(effect)
        }
        backendSyncCoordinator.effectHandler = { [weak self] effect in
            await self?.runBackendSyncEffect(effect)
        }
        controlPlaneCoordinator.effectHandler = { [weak self] effect in
            await self?.runControlPlaneEffect(effect)
        }
        receiveExecutionCoordinator.effectHandler = { [weak self] effect in
            self?.runReceiveExecutionEffect(effect)
        }
        backendCommandCoordinator.effectHandler = { [weak self] effect in
            await self?.runBackendCommandEffect(effect)
        }
        selfCheckCoordinator.effectHandler = { [weak self] effect in
            await self?.runSelfCheckEffect(effect)
        }
        pttSystemPolicyCoordinator.effectHandler = { [weak self] effect in
            await self?.runPTTSystemPolicyEffect(effect)
        }
        pttCoordinator.effectHandler = { [weak self] effect in
            await self?.runPTTEffect(effect)
        }
        transmitCoordinator.effectHandler = { [weak self] effect in
            await self?.runTransmitEffect(effect)
        }
        transmitTaskCoordinator.effectHandler = { [weak self] effect in
            self?.runTransmitTaskEffect(effect)
        }
        controlEventIngestor.effectHandler = { [weak self] effect in
            await self?.runControlEventIngestorEffect(effect)
        }
        controlEventIngestor.ignoredEventReporter = { [weak self] envelope, reason in
            self?.recordIgnoredControlEvent(envelope, reason: reason)
        }
        pttSystemPolicyCoordinator.stateChangeHandler = { [weak self] state in
            guard let defaults = self?.pttSystemPolicyDefaults else { return }
            PTTSystemPolicyPersistence.store(state, to: defaults)
        }
        registerAudioSessionObservers()
        registerApplicationLifecycleObservers()
        registerProximityObserver()
        if !Self.isRunningAutomatedTests {
            startConversationParticipantTelemetryNetworkMonitor()
            startConversationParticipantTelemetryOutputVolumeObserver()
            startConversationParticipantTelemetryPolling()
        }
        if let defaults = pttSystemPolicyDefaults {
            let restoredPolicyState = PTTSystemPolicyPersistence.load(from: defaults)
            if restoredPolicyState != .initial {
                pttSystemPolicyCoordinator.replaceState(restoredPolicyState)
                syncPTTSystemPolicyState()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        conversationParticipantTelemetryPollTask?.cancel()
        conversationParticipantTelemetryOutputVolumeObservation?.invalidate()
        conversationParticipantTelemetryNetworkMonitor?.cancel()
        Task { @MainActor in
            UIDevice.current.isProximityMonitoringEnabled = false
        }
    }

    func currentApplicationState() -> UIApplication.State {
        applicationStateOverride ?? UIApplication.shared.applicationState
    }

    func shouldPublishForegroundPresence(applicationState: UIApplication.State? = nil) -> Bool {
        (applicationState ?? currentApplicationState()) == .active
    }

    func shouldPublishPresenceHeartbeat(applicationState: UIApplication.State? = nil) -> Bool {
        let state = applicationState ?? currentApplicationState()
        return shouldPublishForegroundPresence(applicationState: state)
            || shouldMaintainBackgroundControlPlane(applicationState: state)
    }

    private func beginProtectedBackgroundActivity(named name: String) -> @MainActor () -> Void {
        let lease = BackgroundActivityLease()
        let endLease: @MainActor () -> Void = { [weak self] in
            guard !lease.ended else { return }
            lease.ended = true
            guard lease.identifier != .invalid else { return }
            self?.endBackgroundActivity(lease.identifier)
        }

        lease.identifier = beginBackgroundActivity(name) { [weak self] in
            Task { @MainActor [weak self, endLease, name] in
                self?.diagnostics.record(
                    .app,
                    level: .error,
                    message: "Background handoff expired before completion",
                    metadata: ["name": name]
                )
                endLease()
            }
        }
        return endLease
    }

    private func performProtectedBackgroundHandoff(
        named name: String,
        operation: @escaping @MainActor () async -> Void
    ) async {
        let endLease = beginProtectedBackgroundActivity(named: name)
        defer { endLease() }
        await operation()
    }

    /// Debug knob for the sender-side auto-join UX shortcut.
    /// This keeps the shortcut explicit and reversible without changing
    /// the underlying handshake or backend truth.
    func setSenderAutoJoinOnBeepAcceptanceEnabled(_ enabled: Bool) {
        conversationShortcutPolicy.senderAutoJoinOnBeepAcceptance = enabled
        ConversationShortcutPolicy.store(conversationShortcutPolicy)
        syncSelectedConversationProjection()
    }

    func shouldMaintainBackgroundControlPlane(
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let state = applicationState ?? currentApplicationState()
        guard state != .active else { return true }

        return hasPendingBeginOrActiveTransmit
            || hasActiveTransmitOrMediaSession
            || isJoined
            || pttCoordinator.state.systemChannelUUID != nil
            || pttWakeRuntime.pendingIncomingPush != nil
    }

    func shouldPreserveBackgroundWebSocketForLivePTT(
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let state = applicationState ?? currentApplicationState()
        guard state != .active else { return true }

        if hasPendingBeginOrActiveTransmit
            || isTransmitting
            || transmitCoordinator.state.isPressingTalk
            || pttCoordinator.state.isTransmitting
            || pttWakeRuntime.pendingIncomingPush != nil {
            return true
        }

        guard let contactID = mediaSessionContactID else { return false }
        return hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID)
    }

    func shouldPublishActiveSessionPresenceDuringBackground(
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let state = applicationState ?? currentApplicationState()
        guard state != .active else { return false }

        for contactID in [activeChannelId, selectedContactId, mediaSessionContactID].compactMap({ $0 }) {
            if devicePTTEvidenceExists(for: contactID) {
                return true
            }
        }
        return false
    }

    func syncPTTState() {
        let previousActiveChannelID = activeChannelId
        let resolvedSystemContactID =
            pttCoordinator.state.activeContactID
            ?? pttCoordinator.state.systemChannelUUID.flatMap { contactId(for: $0) }
        if let contactID = resolvedSystemContactID,
           pttCoordinator.state.isJoined {
            forceSyncEngineJoinedConversation(contactID: contactID, reason: "ptt-sync")
        } else if let previousActiveChannelID,
                  engine.snapshot.conversation.joinedEvidence?.friend.contactID.rawValue == previousActiveChannelID.uuidString {
            syncEngineDisconnect(contactID: previousActiveChannelID, reason: "ptt-sync-left")
        }
        if let contactID = resolvedSystemContactID,
           pttCoordinator.state.isTransmitting {
            syncEngineObservedSystemTransmit(
                contactID: contactID,
                channelUUID: pttCoordinator.state.systemChannelUUID,
                reason: "ptt-sync"
            )
        } else if !pttCoordinator.state.isTransmitting,
                  !transmitRuntime.isPressingTalk,
                  !transmitCoordinator.state.isPressingTalk {
            clearEngineTransmitIfActive(reason: "ptt-sync-ended")
        }
        updateAutomaticAudioRouteMonitoring(reason: "ptt-sync")
        captureDiagnosticsState("ptt-sync")
        if let activeChannelId, isJoined {
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                await self.prewarmLocalMediaIfNeeded(
                    for: activeChannelId,
                    applicationState: self.currentApplicationState()
                )
            }
        }
        let readinessContactIDs = Set(
            [previousActiveChannelID, activeChannelId, mediaSessionContactID].compactMap { $0 }
        )
        for contactID in readinessContactIDs {
            Task(priority: .utility) {
                await syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .pttSync)
            }
        }
    }

    var pendingJoinContactId: UUID? {
        conversationActionCoordinator.pendingJoinContactID
    }

    var pendingConnectAcceptedIncomingBeepContactId: UUID? {
        conversationActionCoordinator.pendingConnectAcceptedIncomingBeepContactID
    }

    var transmitProjection: TransmitProjection {
        TransmitProjection(
            controlPlane: transmitCoordinator.state,
            execution: transmitRuntime.executionState,
            systemChannelUUID: pttCoordinator.state.systemChannelUUID,
            systemActiveContactID: pttCoordinator.state.activeContactID,
            systemIsTransmitting: pttCoordinator.state.isTransmitting
        )
    }

    var transmitDomainSnapshot: TransmitDomainSnapshot {
        transmitProjection.domainSnapshot
    }

    var isTransmitPressActive: Bool {
        transmitDomainSnapshot.isPressActive
    }

    func syncTransmitState() {
        if !isTransmitting,
           !transmitCoordinator.state.isPressingTalk,
           transmitCoordinator.state.phase == .idle,
           !transmitRuntime.hasPendingControlPlaneBeginHandoff,
           !hasPendingBeginOrActiveTransmit {
            transmitRuntime.reconcileIdleState()
            localAudioLevel = 0
        }
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-sync")
    }

    func syncPTTSystemPolicyState() {
        pushTokenHex = pttSystemPolicyCoordinator.state.latestTokenHex
        captureDiagnosticsState("ptt-policy-sync")
    }

    func applyAuthenticatedBackendSession(
        client: TurboBackendClient,
        userID: String,
        mode: String,
        telemetryEnabled: Bool = false,
        publicID: String? = nil,
        profileName: String? = nil,
        shareCode: String? = nil,
        shareLink: String? = nil
    ) {
        backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: userID,
            mode: mode,
            telemetryEnabled: telemetryEnabled,
            publicID: publicID,
            profileName: profileName,
            shareCode: shareCode,
            shareLink: shareLink
        )
    }

    func storeAuthenticatedUserID(_ userID: String) {
        backendRuntime.storeAuthenticatedUserID(userID)
    }

    func storeCurrentProfileName(_ profileName: String?) {
        backendRuntime.storeCurrentProfileName(profileName)
    }

    func resetBackendRuntimeForReconnect() {
        backendRuntime.disconnectForReconnect()
        controlPlaneCoordinator.send(.reset)
    }

    func backendBootstrapFailureMessage(
        step: String,
        error: Error,
        baseURL: URL
    ) -> String {
        let host = baseURL.host ?? baseURL.absoluteString
        return "Could not reach \(host) during \(step): \(backendBootstrapFailureReason(error))"
    }

    func backendBootstrapFailureReason(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return error.localizedDescription
        }

        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            return "request timed out"
        case .networkConnectionLost:
            return "network connection was lost"
        case .notConnectedToInternet:
            return "not connected to the internet"
        case .cannotConnectToHost:
            return "cannot connect to host"
        case .cannotFindHost:
            return "cannot find host"
        case .dnsLookupFailed:
            return "DNS lookup failed"
        default:
            return error.localizedDescription
        }
    }

    @discardableResult
    func surfaceLastBackendBootstrapFailureForOnboardingIfPresent() -> Bool {
        guard let message = lastBackendBootstrapFailureMessage else { return false }
        backendStatusMessage = message
        statusMessage = message
        return true
    }

    func replaceBackendConfig(with config: TurboBackendConfig?) {
        backendRuntime.replaceConfig(with: config)
    }

    func replaceBackendPollTask(with task: Task<Void, Never>?) {
        backendRuntime.replacePollTask(with: task)
    }

    func replaceBackendBootstrapRetryTask(with task: Task<Void, Never>?) {
        backendRuntime.replaceBootstrapRetryTask(with: task)
    }

    func replaceBackendSignalingJoinRecoveryTask(with task: Task<Void, Never>?) {
        backendRuntime.replaceSignalingJoinRecoveryTask(with: task)
    }

    func clearTrackedContacts() {
        backendRuntime.clearTrackedContacts()
    }

    func trackContact(_ contactID: UUID) {
        backendRuntime.track(contactID: contactID)
    }

    func untrackContact(_ contactID: UUID) {
        backendRuntime.untrack(contactID: contactID)
    }

    func resetTransportFaults() {
        backendRuntime.transportFaults.reset()
        diagnostics.record(.backend, message: "Reset transport fault injection state")
    }

    func setHTTPTransportDelay(route: TransportFaultHTTPRoute, milliseconds: Int, count: Int) {
        backendRuntime.transportFaults.setHTTPDelay(route: route, milliseconds: milliseconds, count: count)
        diagnostics.record(
            .backend,
            message: "Configured HTTP transport delay",
            metadata: ["route": route.rawValue, "milliseconds": "\(milliseconds)", "count": "\(count)"]
        )
    }

    func setIncomingWebSocketSignalDelay(kind: TurboSignalKind, milliseconds: Int, count: Int) {
        backendRuntime.transportFaults.setWebSocketSignalDelay(
            kind: kind,
            milliseconds: milliseconds,
            count: count
        )
        diagnostics.record(
            .websocket,
            message: "Configured websocket signal delay",
            metadata: ["type": kind.rawValue, "milliseconds": "\(milliseconds)", "count": "\(count)"]
        )
    }

    func dropNextIncomingWebSocketSignals(kind: TurboSignalKind, count: Int) {
        backendRuntime.transportFaults.dropNextWebSocketSignals(kind: kind, count: count)
        diagnostics.record(
            .websocket,
            message: "Configured websocket signal drop",
            metadata: ["type": kind.rawValue, "count": "\(count)"]
        )
    }

    func duplicateNextIncomingWebSocketSignals(kind: TurboSignalKind, count: Int) {
        backendRuntime.transportFaults.duplicateNextWebSocketSignals(kind: kind, count: count)
        diagnostics.record(
            .websocket,
            message: "Configured websocket signal duplication",
            metadata: ["type": kind.rawValue, "count": "\(count)"]
        )
    }

    func reorderNextIncomingWebSocketSignals(kind: TurboSignalKind?, count: Int) {
        backendRuntime.transportFaults.reorderNextWebSocketSignals(kind: kind, count: count)
        diagnostics.record(
            .websocket,
            message: "Configured websocket signal reorder",
            metadata: ["type": kind?.rawValue ?? "any", "count": "\(count)"]
        )
    }

    func cancelPendingTransmitWork() {
        transmitTaskCoordinator.send(.reset)
    }

    func resetTransmitRuntimeOnly() {
        transmitTaskCoordinator.send(.reset)
        transmitRuntime.reset()
        pendingSystemTransmitRetryAfterRejoinByContactID.removeAll()
    }

    func tearDownTransmitRuntime(resetCoordinator: Bool) {
        transmitTaskCoordinator.send(.reset)
        transmitRuntime.reset()
        pendingSystemTransmitRetryAfterRejoinByContactID.removeAll()
        localTransmitStopProjectionGraceStartedAtNanosecondsByContactID.removeAll()
        localTransmitStopProjectionGraceStartedAtMillisecondsByContactID.removeAll()
        clearFirstAudioPlaybackAckExpectations()
        pendingBeginTransmitAfterSettlingTask?.cancel()
        pendingBeginTransmitAfterSettlingTask = nil
        if resetCoordinator {
            transmitCoordinator.reset()
            syncTransmitState()
        }
    }

    func resetTransmitSession(closeMediaSession shouldCloseMediaSession: Bool) {
        clearEngineTransmitIfActive(reason: "reset-transmit-session")
        tearDownTransmitRuntime(resetCoordinator: true)
        if shouldCloseMediaSession {
            closeMediaSession()
        }
    }

    var selectedContact: Contact? {
        guard let selectedContactId else { return nil }
        return contacts.first { $0.id == selectedContactId }
    }

    var backendConfig: TurboBackendConfig? {
        backendRuntime.config
    }

    var hasBackendConfig: Bool {
        backendConfig != nil
    }

    var backendServices: BackendServices? {
        let runtime = backendRuntime
        guard let client = runtime.client else { return nil }
        return BackendServices(
            client: client,
            criticalHTTPClient: client.criticalHTTPClient,
            currentUserID: runtime.currentUserID,
            mode: runtime.mode,
            telemetryEnabled: runtime.telemetryEnabled
        )
    }

    var isDirectPathRelayOnlyForced: Bool {
        TurboDirectPathDebugOverride.isRelayOnlyForced()
    }

    var isDirectQuicAutoUpgradeDisabledForDebug: Bool {
        TurboDirectPathDebugOverride.isAutoUpgradeDisabled()
    }

    var directQuicTransmitStartupPolicy: DirectQuicTransmitStartupPolicy {
        TurboDirectPathDebugOverride.transmitStartupPolicy()
    }

    var backendAdvertisesDirectQuicUpgrade: Bool {
        backendServices?.supportsDirectQuicUpgrade == true
    }

    var effectiveDirectQuicUpgradeEnabled: Bool {
        backendAdvertisesDirectQuicUpgrade
            && !isDirectPathRelayOnlyForced
            && !TurboMediaRelayDebugOverride.isForced()
    }

    var selectedDirectQuicDiagnosticsSummary: DirectQuicDiagnosticsSummary {
        let contactID = selectedContactId
        let selectedHandle = selectedContact?.handle
        let attempt = contactID.flatMap { mediaRuntime.directQuicUpgrade.attempt(for: $0) }
        let retryBackoff = contactID.flatMap { mediaRuntime.directQuicUpgrade.retryBackoffState(for: $0) }
        let retryRemainingMilliseconds = contactID.flatMap {
            mediaRuntime.directQuicUpgrade.retryBackoffRemaining(for: $0).map { Int($0 * 1_000) }
        }
        let directQuicPolicy = backendServices?.directQuicPolicy
        let mediaRelayConfig = TurboMediaRelayDebugOverride.config()
        let localDeviceID = backendServices?.deviceID
        let peerDeviceID = attempt?.peerDeviceID ?? contactID.flatMap { directQuicPeerDeviceID(for: $0) }
        let identityStatus = DirectQuicIdentityConfiguration.status()
        let installedIdentityCount = DirectQuicIdentityConfiguration.installedIdentityCount()
        let directQuicRole = localDeviceID.flatMap { localDeviceID in
            peerDeviceID.map { peerDeviceID in
                directQuicAttemptRole(
                    localDeviceID: localDeviceID,
                    peerDeviceID: peerDeviceID
                )
            }
        }

        return DirectQuicDiagnosticsSummary(
            selectedHandle: selectedHandle,
            role: directQuicRole.map { role in
                switch role {
                case .listenerOfferer:
                    return "listener-offerer"
                case .dialerAnswerer:
                    return "dialer-answerer"
                }
            },
            identityLabel: identityStatus.resolvedLabel,
            identityStatus: identityStatus.diagnosticsText,
            identitySource: identityStatus.source.rawValue,
            fingerprint: identityStatus.fingerprint,
            provisioningStatus: directQuicProvisioningStatus,
            installedIdentityCount: installedIdentityCount,
            relayOnlyOverride: isDirectPathRelayOnlyForced,
            autoUpgradeDisabled: isDirectQuicAutoUpgradeDisabledForDebug,
            transmitStartupPolicy: directQuicTransmitStartupPolicy,
            mediaRelayEnabled: TurboMediaRelayDebugOverride.isEnabled(),
            mediaRelayForced: TurboMediaRelayDebugOverride.isForced(),
            mediaRelayConfigured: mediaRelayConfig?.isConfigured == true,
            mediaRelayHost: mediaRelayConfig?.host,
            mediaRelayQuicPort: mediaRelayConfig.map { Int($0.quicPort) },
            mediaRelayTcpPort: mediaRelayConfig.map { Int($0.tcpPort) },
            mediaRelayActive: mediaRuntime.mediaRelayClient != nil,
            audioPacketDiagnosticsEnabled: TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled(),
            backendAdvertisesUpgrade: backendAdvertisesDirectQuicUpgrade,
            effectiveUpgradeEnabled: effectiveDirectQuicUpgradeEnabled,
            transportPathState: mediaTransportPathState,
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID,
            attemptID: attempt?.attemptId,
            channelID: attempt?.channelID,
            isDirectActive: attempt?.isDirectActive ?? false,
            remoteCandidateCount: attempt?.remoteCandidateCount ?? 0,
            remoteEndOfCandidates: attempt?.remoteEndOfCandidates ?? false,
            attemptStartedAt: attempt?.startedAt,
            lastUpdatedAt: attempt?.lastUpdatedAt,
            nominatedPathSource: attempt?.nominatedPath?.source.rawValue,
            nominatedRemoteAddress: attempt?.nominatedPath?.remoteAddress,
            nominatedRemotePort: attempt?.nominatedPath?.remotePort,
            nominatedRemoteCandidateKind: attempt?.nominatedPath?.remoteCandidateKind?.rawValue,
            retryReason: retryBackoff?.reason,
            retryCategory: retryBackoff?.category.rawValue,
            retryAttemptID: retryBackoff?.attemptId,
            retryRemainingMilliseconds: retryRemainingMilliseconds,
            retryBackoffMilliseconds: retryBackoff?.milliseconds,
            stunServerCount: directQuicPolicy?.effectiveStunServers.count ?? 0,
            stunProviderNames: directQuicPolicy?.enabledStunProviderNames ?? [],
            turnEnabled: directQuicPolicy?.turnEnabled == true,
            turnProvider: directQuicPolicy?.turnProvider,
            turnPolicyPath: directQuicPolicy?.turnPolicyPath,
            turnCredentialTtlSeconds: directQuicPolicy?.turnCredentialTtlSeconds,
            transportExperimentBucket: directQuicPolicy?.transportExperimentBucket,
            promotionTimeoutMilliseconds: directQuicPromotionTimeoutMilliseconds(),
            retryBackoffBaseMilliseconds: directQuicRetryBackoffMilliseconds(),
            probeControllerReady: mediaRuntime.directQuicProbeController != nil
        )
    }

    var latestSelfCheckReport: DevSelfCheckReport? {
        selfCheckCoordinator.state.latestReport
    }

    var hasPendingBackendPollTask: Bool {
        backendRuntime.pollTask != nil
    }

    var trackedContactIDs: Set<UUID> {
        backendRuntime.trackedContactIDs
    }

    var mediaServices: MediaServices {
        MediaServices(
            session: { [weak self] in
                self?.mediaRuntime.session
            },
            contactID: { [weak self] in
                self?.mediaRuntime.contactID
            },
            hasSession: { [weak self] in
                self?.mediaRuntime.hasSession ?? false
            },
            sendAudioChunk: { [weak self] in
                self?.mediaRuntime.sendAudioChunk
            },
            attach: { [weak self] session, contactID in
                self?.mediaRuntime.attach(session: session, contactID: contactID)
            },
            updateConnectionState: { [weak self] state in
                self?.mediaRuntime.updateConnectionState(state)
            },
            isStartupInFlight: { [weak self] context in
                self?.mediaRuntime.isStartupInFlight(for: context) ?? false
            },
            shouldDelayRetry: { [weak self] context, cooldown in
                self?.mediaRuntime.shouldDelayRetry(for: context, cooldown: cooldown) ?? false
            },
            markStartupInFlight: { [weak self] context in
                self?.mediaRuntime.markStartupInFlight(context)
            },
            markStartupSucceeded: { [weak self] in
                self?.mediaRuntime.markStartupSucceeded()
            },
            markStartupFailed: { [weak self] context, message in
                self?.mediaRuntime.markStartupFailed(context, message: message)
            },
            replaceSendAudioChunk: { [weak self] handler in
                self?.mediaRuntime.replaceSendAudioChunk(with: handler)
            },
            reset: { [weak self] deactivateAudioSession, preserveDirectQuic, preserveMediaRelay in
                self?.mediaRuntime.reset(
                    deactivateAudioSession: deactivateAudioSession,
                    preserveDirectQuic: preserveDirectQuic,
                    preserveMediaRelay: preserveMediaRelay
                )
            }
        )
    }

    var mediaConnectionState: MediaConnectionState {
        mediaRuntime.connectionState
    }

    var mediaTransportPathState: MediaTransportPathState {
        mediaRuntime.transportPathState
    }

    var mediaSessionContactID: UUID? {
        mediaRuntime.contactID
    }

    var hasPendingBeginOrActiveTransmit: Bool {
        transmitTaskCoordinator.state.hasPendingBeginOrActiveTarget(
            activeTarget: transmitProjection.activeTarget
        )
    }

    var hasActiveTransmitOrMediaSession: Bool {
        transmitProjection.activeTarget != nil || mediaServices.session() != nil
    }

    var isRunningSelfCheck: Bool {
        selfCheckCoordinator.state.isRunning
    }

    var backendStatusMessage: String {
        get { backendSyncCoordinator.state.syncState.statusMessage }
        set { backendSyncCoordinator.send(.statusMessageUpdated(newValue)) }
    }

    var currentDevUserHandle: String {
        backendRuntime.config?.devUserHandle ?? "bb-local"
    }

    var currentIdentityHandle: String {
        let rawHandle =
            backendRuntime.currentShareCode
            ?? backendRuntime.currentPublicID
            ?? currentDevUserHandle
        return Contact.normalizedHandle(rawHandle)
    }

    var currentContactAliasOwnerKey: String {
        backendRuntime.currentUserID
            ?? backendRuntime.currentPublicID
            ?? currentIdentityHandle
    }

    var currentProfileName: String {
        if let currentProfileName = backendRuntime.currentProfileName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !currentProfileName.isEmpty {
            return currentProfileName
        }
        return TurboIdentityProfileStore.draftProfileName()
    }

    var currentIdentityShareLink: String {
        if let currentShareLink = backendRuntime.currentShareLink,
           !currentShareLink.isEmpty {
            return currentShareLink
        }

        let pathComponent = TurboHandle.sharePathComponent(from: currentIdentityHandle)
        let encodedHandle =
            pathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? pathComponent
        return "https://beepbeep.to/\(encodedHandle)"
    }

    var developerIdentityControlsEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    var hasCompletedIdentityOnboarding: Bool {
        TurboIdentityProfileStore.hasCompletedOnboarding()
    }

    var appVersionDescription: String {
        let shortVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        let buildNumber =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? shortVersion
        return shortVersion == buildNumber ? shortVersion : "\(shortVersion) (\(buildNumber))"
    }

    var availableDevUserHandles: [String] {
        guard developerIdentityControlsEnabled else { return [currentDevUserHandle] }
        return Array(
            Set(([currentDevUserHandle] + ContactDirectory.suggestedDevHandles).map(Contact.normalizedHandle))
        ).sorted()
    }

    var quickFriendHandles: [String] {
        guard developerIdentityControlsEnabled else { return [] }
        return ["@avery", "@blake"]
            .map(Contact.normalizedHandle)
            .filter { $0 != currentDevUserHandle }
    }

    var shouldShowContactsLoadingPlaceholder: Bool {
        guard contacts.isEmpty, activeConversationContact == nil else { return false }
        if systemSessionState != .none { return true }
        if backendRuntime.bootstrapRetryTask != nil { return true }
        return !backendRuntime.isReady && backendRuntime.hasClient
    }

    var topChromeDiagnosticsErrorText: String? {
        guard developerIdentityControlsEnabled else { return nil }
        guard let latestError = diagnostics.latestError else { return nil }
        guard shouldSurfaceTopChromeDiagnosticsError(latestError) else { return nil }
        return "\(latestError.subsystem.rawValue): \(latestError.message)"
    }

    var topChromeStatusMessage: String? {
        if developerIdentityControlsEnabled {
            guard !isRedundantSelectedPresenceStatus(statusMessage) else { return nil }
            return statusMessage
        }
        guard shouldSurfaceConnectionProblemInTopChrome else { return nil }
        return "Offline"
    }

    private func isRedundantSelectedPresenceStatus(_ message: String) -> Bool {
        guard let selectedContact else { return false }
        return message == "\(selectedContact.name) is online"
            || message == "\(selectedContact.handle) is online"
    }

    var usesLocalHTTPBackend: Bool {
        backendRuntime.mode == "local-http"
    }

    private var shouldSurfaceConnectionProblemInTopChrome: Bool {
        if backendRuntime.bootstrapRetryTask != nil { return true }
        if !backendRuntime.isReady, backendRuntime.hasClient { return true }

        let normalizedBackendStatus = backendStatusMessage.lowercased()
        if normalizedBackendStatus.contains("unavailable")
            || normalizedBackendStatus.contains("connection failed")
            || normalizedBackendStatus.contains("disconnected")
            || normalizedBackendStatus.contains("reconnecting") {
            return true
        }

        let normalizedPrimaryStatus = statusMessage.lowercased()
        return normalizedPrimaryStatus.contains("unavailable")
            || normalizedPrimaryStatus.contains("connection failed")
            || normalizedPrimaryStatus.contains("reconnecting")
    }

    private func shouldSurfaceTopChromeDiagnosticsError(_ entry: DiagnosticsEntry) -> Bool {
        if entry.subsystem == .invariant {
            guard let invariantID = entry.metadata["invariantID"] else { return false }
            return stateMachineProjection.devicePTT.derivedInvariantIDs.contains(invariantID)
        }

        switch (entry.subsystem, entry.message) {
        case (.backend, "Backend connection failed"):
            return shouldProjectBackendConnectivityInPrimaryStatus
                && shouldSurfaceConnectionProblemInTopChrome
        case (.channel, "Channel state refresh failed"),
             (.channel, "Channel state refresh failed; preserving local Conversation evidence"):
            return shouldSurfaceConnectionProblemInTopChrome
        case (.pushToTalk, "PTT init failed"):
            return !pttSystemClient.isReady
        case (.media, "Direct QUIC media path lost"):
            return false
        default:
            return true
        }
    }

    var selectedConversationDiagnosticsSummary: SelectedConversationDiagnosticsSummary {
        let selectedState: SelectedConversationState
        let selectedChannelProjection: ChannelReadinessSnapshot?
        if let selectedContactId {
            selectedState = selectedConversationState(for: selectedContactId)
            selectedChannelProjection = self.selectedChannelSnapshot(for: selectedContactId)
        } else {
            selectedState = SelectedConversationState(
                relationship: .none,
                phase: .idle,
                statusMessage: "Ready to connect",
                canTransmitNow: false
            )
            selectedChannelProjection = nil
        }

        return SelectedConversationDiagnosticsSummary(
            selectedHandle: selectedContact?.handle,
            selectedPhase: String(describing: selectedState.phase),
            selectedPhaseDetail: String(describing: selectedState.detail),
            relationship: String(describing: selectedState.relationship),
            statusMessage: selectedState.statusMessage,
            canTransmitNow: selectedState.canTransmitNow,
            allowsHoldToTalk: selectedState.allowsHoldToTalk,
            isJoined: isJoined,
            isTransmitting: isTransmitting,
            activeChannelID: activeChannelId?.uuidString,
            pendingAction: String(describing: conversationActionCoordinator.pendingAction),
            reconciliationAction: String(describing: selectedConversationCoordinator.state.reconciliationAction),
            hadConnectedDevicePTTContinuity: selectedContactId == nil
                ? false
                : selectedConversationCoordinator.state.hadConnectedDevicePTTContinuity,
            systemSession: String(describing: systemSessionState),
            mediaState: String(describing: mediaRuntime.connectionState),
            backendChannelStatus: selectedChannelProjection?.status?.rawValue,
            backendReadiness: selectedChannelProjection?.readinessStatus?.kind,
            backendMembership: selectedChannelProjection.map { String(describing: $0.membership) },
            backendBeepThreadProjection: selectedChannelProjection.map { String(describing: $0.beepThreadProjection) },
            backendSelfJoined: selectedChannelProjection.map { $0.membership.hasLocalMembership },
            backendPeerJoined: selectedChannelProjection.map { $0.membership.hasPeerMembership },
            backendPeerDeviceConnected: selectedChannelProjection.map { $0.membership.peerDeviceConnected },
            backendActiveTransmitterUserId: selectedChannelProjection?.activeTransmitterUserId,
            backendActiveTransmitId: selectedChannelProjection?.activeTransmitId,
            backendActiveTransmitExpiresAt: selectedChannelProjection?.activeTransmitExpiresAt,
            backendServerTimestamp: selectedChannelProjection?.serverTimestamp,
            remoteAudioReadiness: selectedChannelProjection.map { String(describing: $0.remoteAudioReadiness) },
            remoteWakeCapability: selectedChannelProjection.map { String(describing: $0.remoteWakeCapability) },
            remoteWakeCapabilityKind: selectedChannelProjection.map {
                switch $0.remoteWakeCapability {
                case .unavailable:
                    return "unavailable"
                case .wakeCapable:
                    return "wake-capable"
                }
            },
            backendCanTransmit: selectedChannelProjection.map(\.canTransmit),
            firstTalkStartupProfile: selectedContactId.map {
                firstTalkStartupProfile(for: $0, startGraceIfNeeded: false).diagnosticsValue
            },
            pttTokenRegistrationKind: pttSystemPolicyCoordinator.state.tokenRegistrationKind,
            incomingWakeActivationState: selectedContact.flatMap { contact in
                pttWakeRuntime.incomingWakeActivationState(for: contact.id).map { String(describing: $0) }
            },
            incomingWakeBufferedChunkCount: selectedContact.map {
                pttWakeRuntime.bufferedAudioChunkCount(for: $0.id)
            }
        )
    }

    func devicePTTDiagnosticsProjection(
        selectedConversation: SelectedConversationDiagnosticsSummary
    ) -> DevicePTTDiagnosticsProjection {
        let selectedContactID = selectedContactId
        let selectedRemoteReceiveActivity = selectedContactID.flatMap {
            receiveExecutionCoordinator.state.remoteActivityByContactID[$0]
        }
        let selectedReceiverAudioReadiness = selectedContactID.flatMap {
            controlPlaneCoordinator.state.receiverAudioReadinessStates[$0]
        }
        let transmitSnapshot = transmitDomainSnapshot
        let systemState = pttCoordinator.state
        let localJoinAttempt = conversationActionCoordinator.localJoinAttempt
        let remotePlaybackContinuity = RemotePlaybackContinuityState(
            drainBlocksTransmit: selectedContactID.map {
                remotePlaybackDrainBlocksLocalTransmit(for: $0)
            } ?? false,
            stopObserved: selectedContactID.map {
                receiveExecutionCoordinator.state.remoteTransmitStoppedContactIDs.contains($0)
            } ?? false,
            stopProjectionGraceActive: selectedContactID.map {
                remoteTransmitStopProjectionGraceIsActive(for: $0)
            } ?? false
        )
        let backendConvergence = BackendConversationConvergenceState(
            joinSettling: selectedContactID.map {
                backendJoinIsSettling(for: $0)
            } ?? false,
            signalingJoinRecoveryActive: backendRuntime.signalingJoinRecoveryTask != nil,
            controlPlaneReconnectGraceActive: selectedContactID.map {
                shouldUseLiveCallControlPlaneReconnectGrace(for: $0)
            } ?? false
        )
        let selectedSystemSessionMatches = selectedContactID.map {
            systemSessionMatches($0)
        } ?? false

        return DevicePTTDiagnosticsProjection(
            selectedContactID: selectedContactID?.uuidString,
            selectedHandle: selectedConversation.selectedHandle,
            selectedConversationPhase: selectedConversation.selectedPhase,
            selectedConversationPhaseDetail: selectedConversation.selectedPhaseDetail,
            selectedConversationRelationship: selectedConversation.relationship,
            selectedConversationCanTransmit: selectedConversation.canTransmitNow,
            selectedConversationAllowsHoldToTalk: selectedConversation.allowsHoldToTalk,
            selectedConversationAutoJoinArmed: selectedConversationCoordinator.state
                .senderAutoJoinOnBeepAcceptanceArmed,
            isJoined: selectedSystemSessionMatches,
            isTransmitting: isTransmitting,
            activeChannelID: (selectedSystemSessionMatches ? selectedContactID : nil)?.uuidString,
            systemSession: selectedConversation.systemSession,
            systemActiveContactID: systemState.activeContactID?.uuidString,
            systemChannelUUID: systemState.systemChannelUUID?.uuidString,
            mediaState: selectedConversation.mediaState,
            transmitPhase: String(describing: transmitSnapshot.phase),
            transmitActiveContactID: transmitSnapshot.activeContactID?.uuidString,
            transmitPressActive: transmitSnapshot.isPressActive,
            transmitExplicitStopRequested: transmitSnapshot.explicitStopRequested,
            transmitSystemTransmitting: transmitSnapshot.isSystemTransmitting,
            incomingWakeActivationState: selectedConversation.incomingWakeActivationState,
            incomingWakeBufferedChunkCount: selectedConversation.incomingWakeBufferedChunkCount,
            remoteReceiveActive: selectedRemoteReceiveActivity?.phase.isPeerTransmitting == true,
            remoteTransmitStopObserved: remotePlaybackContinuity.stopObserved,
            remoteTransmitStopProjectionGraceActive: remotePlaybackContinuity.stopProjectionGraceActive,
            remoteReceiveActivityState: selectedRemoteReceiveActivity.map { String(describing: $0) },
            receiverAudioReadinessState: selectedReceiverAudioReadiness.map { String(describing: $0) },
            pendingAction: selectedConversation.pendingAction,
            localJoinAttempt: localJoinAttempt.map {
                "contactID:\($0.contactID.uuidString),channelUUID:\($0.channelUUID.uuidString)"
            },
            localJoinAttemptIssuedCount: localJoinAttempt?.issuedCount ?? 0,
            reconciliationAction: selectedConversation.reconciliationAction,
            hadConnectedDevicePTTContinuity: selectedConversation.hadConnectedDevicePTTContinuity,
            controlPlaneReconnectGraceActive: backendConvergence.controlPlaneReconnectGraceActive,
            backendSignalingJoinRecoveryActive: backendConvergence.backendSignalingJoinRecoveryActive,
            backendJoinSettling: backendConvergence.backendJoinSettling,
            backendChannelStatus: selectedConversation.backendChannelStatus,
            backendReadiness: selectedConversation.backendReadiness,
            backendSelfJoined: selectedConversation.backendSelfJoined,
            backendPeerJoined: selectedConversation.backendPeerJoined,
            backendPeerDeviceConnected: selectedConversation.backendPeerDeviceConnected,
            backendActiveTransmitterUserId: selectedConversation.backendActiveTransmitterUserId,
            backendActiveTransmitId: selectedConversation.backendActiveTransmitId,
            backendActiveTransmitExpiresAt: selectedConversation.backendActiveTransmitExpiresAt,
            backendServerTimestamp: selectedConversation.backendServerTimestamp,
            backendCanTransmit: selectedConversation.backendCanTransmit,
            remoteAudioReadiness: selectedConversation.remoteAudioReadiness,
            remoteWakeCapabilityKind: selectedConversation.remoteWakeCapabilityKind
        )
    }

    var contactDiagnosticsSummaries: [ContactDiagnosticsSummary] {
        contacts
            .filter { $0.handle != currentDevUserHandle }
            .sorted { $0.handle < $1.handle }
            .map { contact in
                let summary = contactSummaryByContactID[contact.id]
                let listItem = contactListItem(for: contact)
                let relationship = beepThreadProjection(for: contact.id)
                let relationshipDescription: String = switch relationship {
                case .none:
                    "none"
                case .outgoingBeep(let requestCount):
                    "outgoing(requestCount: \(requestCount))"
                case .incomingBeep(let requestCount):
                    "incoming(requestCount: \(requestCount))"
                case .mutualBeep(let requestCount):
                    "mutual(requestCount: \(requestCount))"
                }
                return ContactDiagnosticsSummary(
                    handle: contact.handle,
                    isOnline: summary?.isOnline ?? contact.isOnline,
                    listState: listConversationState(for: contact.id).rawValue,
                    badgeStatus: summary?.badgeKind,
                    listSection: listItem.presentation.section.rawValue,
                    presencePill: listItem.presentation.availabilityPill.rawValue,
                    beepThreadProjection: relationshipDescription,
                    hasIncomingBeep: relationship.hasIncomingBeep,
                    hasOutgoingBeep: relationship.hasOutgoingBeep,
                    requestCount: listItem.presentation.requestCount ?? 0,
                    incomingBeepCount: incomingBeepByContactID[contact.id]?.requestCount,
                    outgoingBeepCount: outgoingBeepByContactID[contact.id]?.requestCount
                )
            }
    }

    var stateMachineProjection: StateMachineProjection {
        let selectedConversation = selectedConversationDiagnosticsSummary
        return StateMachineProjection(
            selectedConversation: selectedConversation,
            devicePTT: devicePTTDiagnosticsProjection(selectedConversation: selectedConversation),
            contacts: contactDiagnosticsSummaries,
            isWebSocketConnected: backendRuntime.isWebSocketConnected,
            statusMessage: statusMessage,
            backendStatusMessage: backendStatusMessage
        )
    }

    var diagnosticsStateFields: [String: String] {
        let projection = stateMachineProjection
        let selectedConversation = projection.selectedConversation
        let directQuic = selectedDirectQuicDiagnosticsSummary
        let pendingIncomingPushDescription: String
        let pendingIncomingPushActivated: String
        if let push = pttWakeRuntime.pendingIncomingPush {
            let pushContactHandle = contacts.first(where: { $0.id == push.contactID })?.handle
                ?? push.contactID.uuidString
            pendingIncomingPushDescription = "\(push.payload.event.rawValue):\(pushContactHandle)"
            pendingIncomingPushActivated = String(push.playbackMode == .systemActivated)
        } else {
            pendingIncomingPushDescription = "none"
            pendingIncomingPushActivated = "false"
        }
        let localJoinAttemptDescription: String
        let localJoinAttemptIssuedCount: String
        let engineSnapshot = engine.snapshot
        if let attempt = conversationActionCoordinator.localJoinAttempt {
            localJoinAttemptDescription =
                "contactID:\(attempt.contactID.uuidString),channelUUID:\(attempt.channelUUID.uuidString)"
            localJoinAttemptIssuedCount = String(attempt.issuedCount)
        } else {
            localJoinAttemptDescription = "none"
            localJoinAttemptIssuedCount = "0"
        }
        var fields: [String: String] = [
            "identity": currentDevUserHandle,
            "selectedContact": selectedContact?.handle ?? "none",
            "selectedConversationPhase": selectedConversation.selectedPhase,
            "selectedConversationPhaseDetail": selectedConversation.selectedPhaseDetail,
            "selectedConversationRelationship": selectedConversation.relationship,
            "selectedConversationStatus": selectedConversation.statusMessage,
            "selectedConversationCanTransmit": String(selectedConversation.canTransmitNow),
            "selectedConversationAllowsHoldToTalk": String(selectedConversation.allowsHoldToTalk),
            "pendingAction": selectedConversation.pendingAction,
            "localJoinAttempt": localJoinAttemptDescription,
            "localJoinAttemptIssuedCount": localJoinAttemptIssuedCount,
            "selectedConversationReconciliationAction": selectedConversation.reconciliationAction,
            "selectedConversationAutoJoinEnabled": String(
                conversationShortcutPolicy.senderAutoJoinOnBeepAcceptance
            ),
            "selectedConversationAutoJoinArmed": String(
                selectedConversationCoordinator.state.senderAutoJoinOnBeepAcceptanceArmed
            ),
            "audioPacketDiagnostics": TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled()
                ? "enabled"
                : "off",
            "hadConnectedDevicePTTContinuity": String(selectedConversation.hadConnectedDevicePTTContinuity),
            "backendSignalingJoinRecoveryActive": String(backendRuntime.signalingJoinRecoveryTask != nil),
            "backendJoinSettling": String(
                selectedContactId.map { backendJoinIsSettling(for: $0) } ?? false
            ),
            "activeChannelId": activeChannelId?.uuidString ?? "none",
            "isJoined": String(isJoined),
            "isTransmitting": String(isTransmitting),
            "engineConversation": String(describing: engineSnapshot.conversation),
            "engineTransmit": String(describing: engineSnapshot.transmit),
            "engineReceive": String(describing: engineSnapshot.receive),
            "engineTransport": String(describing: engineSnapshot.transport),
            "engineLifecycle": String(describing: engineSnapshot.lifecycle),
            "enginePTTAudio": String(describing: engineSnapshot.pttAudio),
            "engineScheduledPlaybackCount": String(engineSnapshot.scheduledPlaybackCount),
            "transmitPhase": String(describing: transmitDomainSnapshot.phase),
            "transmitPressActive": String(transmitDomainSnapshot.isPressActive),
            "transmitExplicitStopRequested": String(transmitDomainSnapshot.explicitStopRequested),
            "transmitSystemTransmitting": String(transmitDomainSnapshot.isSystemTransmitting),
            "isBackendReady": String(backendRuntime.isReady),
            "backendMode": backendRuntime.mode,
            "systemSession": String(describing: systemSessionState),
            "remoteTransmitStopObserved": String(
                selectedContactId.map {
                    receiveExecutionCoordinator.state.remoteTransmitStoppedContactIDs.contains($0)
                } ?? false
            ),
            "remoteTransmitStopProjectionGraceActive": String(
                selectedContactId.map {
                    self.remoteTransmitStopProjectionGraceIsActive(for: $0)
                } ?? false
            ),
            "remotePlaybackDrainBlocksTransmit": String(
                selectedContactId.map {
                    self.remotePlaybackDrainBlocksLocalTransmit(for: $0)
                } ?? false
            ),
            "pttClientMode": pttSystemClient.modeDescription,
            "pttTokenRegistration": pttSystemPolicyCoordinator.state.tokenRegistrationDescription,
            "pttTokenRegistrationKind": pttSystemPolicyCoordinator.state.tokenRegistrationKind,
            "pttUploadedBackendChannelId": pttSystemPolicyCoordinator.state.uploadedBackendChannelID ?? "none",
            "pttTokenUploadError": pttSystemPolicyCoordinator.state.lastTokenUploadError ?? "none",
            "pendingIncomingPush": pendingIncomingPushDescription,
            "pendingIncomingPushActivated": pendingIncomingPushActivated,
            "incomingWakeActivationState": selectedConversation.incomingWakeActivationState ?? "none",
            "incomingWakeBufferedChunkCount": selectedConversation.incomingWakeBufferedChunkCount.map(String.init(describing:)) ?? "0",
            "localJoinFailure": pttCoordinator.state.lastJoinFailure.map(String.init(describing:)) ?? "none",
            "websocket": backendRuntime.isWebSocketConnected ? "connected" : "disconnected",
            "mediaState": String(describing: mediaRuntime.connectionState),
            "backendChannelStatus": selectedConversation.backendChannelStatus ?? "none",
            "backendReadiness": selectedConversation.backendReadiness ?? "none",
            "backendMembership": selectedConversation.backendMembership ?? "none",
            "backendBeepThreadProjection": selectedConversation.backendBeepThreadProjection ?? "none",
            "backendSelfJoined": selectedConversation.backendSelfJoined.map(String.init(describing:)) ?? "none",
            "backendPeerJoined": selectedConversation.backendPeerJoined.map(String.init(describing:)) ?? "none",
            "backendPeerDeviceConnected": selectedConversation.backendPeerDeviceConnected.map(String.init(describing:)) ?? "none",
            "backendActiveTransmitterUserId": selectedConversation.backendActiveTransmitterUserId ?? "none",
            "backendActiveTransmitId": selectedConversation.backendActiveTransmitId ?? "none",
            "backendActiveTransmitExpiresAt": selectedConversation.backendActiveTransmitExpiresAt ?? "none",
            "backendServerTimestamp": selectedConversation.backendServerTimestamp ?? "none",
            "remoteAudioReadiness": selectedConversation.remoteAudioReadiness ?? "unknown",
            "remoteWakeCapability": selectedConversation.remoteWakeCapability ?? "unavailable",
            "remoteWakeCapabilityKind": selectedConversation.remoteWakeCapabilityKind ?? "unavailable",
            "backendCanTransmit": selectedConversation.backendCanTransmit.map(String.init(describing:)) ?? "none",
            "firstTalkStartupProfile": selectedConversation.firstTalkStartupProfile ?? "none",
            "directQuicRelayOnlyOverride": String(directQuic.relayOnlyOverride),
            "directQuicAutoUpgradeDisabled": String(directQuic.autoUpgradeDisabled),
            "directQuicTransmitStartupPolicy": directQuic.transmitStartupPolicy.rawValue,
            "directQuicBackendAdvertised": String(directQuic.backendAdvertisesUpgrade),
            "directQuicEnabled": String(directQuic.effectiveUpgradeEnabled),
            "mediaRelayEnabled": String(directQuic.mediaRelayEnabled),
            "mediaRelayForced": String(directQuic.mediaRelayForced),
            "mediaRelayConfigured": String(directQuic.mediaRelayConfigured),
            "mediaRelayActive": String(directQuic.mediaRelayActive),
            "directQuicRole": directQuic.role ?? "none",
            "directQuicIdentityLabel": directQuic.identityLabel ?? "none",
            "directQuicIdentityStatus": directQuic.identityStatus,
            "directQuicIdentitySource": directQuic.identitySource,
            "directQuicProvisioningStatus": directQuic.provisioningStatus,
            "directQuicFingerprint": directQuic.fingerprint ?? "none",
            "directQuicInstalledIdentityCount": String(directQuic.installedIdentityCount),
            "directQuicTransportPath": directQuic.transportPathState.rawValue,
            "directQuicLocalDeviceId": directQuic.localDeviceID ?? "none",
            "directQuicPeerDeviceId": directQuic.peerDeviceID ?? "none",
            "directQuicAttemptId": directQuic.attemptID ?? "none",
            "directQuicChannelId": directQuic.channelID ?? "none",
            "directQuicIsActive": String(directQuic.isDirectActive),
            "directQuicRemoteCandidateCount": String(directQuic.remoteCandidateCount),
            "directQuicRemoteEndOfCandidates": String(directQuic.remoteEndOfCandidates),
            "directQuicNominatedPathSource": directQuic.nominatedPathSource ?? "none",
            "directQuicNominatedRemoteAddress": directQuic.nominatedRemoteAddress ?? "none",
            "directQuicNominatedRemotePort": directQuic.nominatedRemotePort.map(String.init) ?? "none",
            "directQuicNominatedRemoteCandidateKind": directQuic.nominatedRemoteCandidateKind ?? "none",
            "directQuicRetryReason": directQuic.retryReason ?? "none",
            "directQuicRetryCategory": directQuic.retryCategory ?? "none",
            "directQuicRetryAttemptId": directQuic.retryAttemptID ?? "none",
            "directQuicRetryRemainingMs": directQuic.retryRemainingMilliseconds.map(String.init) ?? "none",
            "directQuicRetryBackoffMs": directQuic.retryBackoffMilliseconds.map(String.init) ?? "none",
            "directQuicStunServerCount": String(directQuic.stunServerCount),
            "directQuicStunProviders": directQuic.stunProviderNames.joined(separator: ","),
            "directQuicTurnEnabled": String(directQuic.turnEnabled),
            "directQuicTurnProvider": directQuic.turnProvider ?? "none",
            "directQuicTurnPolicyPath": directQuic.turnPolicyPath ?? "none",
            "directQuicTurnCredentialTtlSeconds": directQuic.turnCredentialTtlSeconds.map(String.init) ?? "none",
            "directQuicTransportExperimentBucket": directQuic.transportExperimentBucket ?? "none",
            "directQuicPromotionTimeoutMs": String(directQuic.promotionTimeoutMilliseconds),
            "directQuicRetryBackoffBaseMs": String(directQuic.retryBackoffBaseMilliseconds),
            "directQuicProbeControllerReady": String(directQuic.probeControllerReady),
            "status": statusMessage,
            "backendStatus": backendStatusMessage
        ]
        fields.merge(uiProjectionDiagnostics.fields) { _, new in new }
        return fields
    }

    var diagnosticsSnapshot: String {
        let coreLines = diagnosticsStateFields.keys.sorted().map { "\($0)=\(diagnosticsStateFields[$0] ?? "")" }
        let contactLines = stateMachineProjection.contacts.flatMap { summary in
            [
                "contact[\(summary.handle)].isOnline=\(summary.isOnline)",
                "contact[\(summary.handle)].listState=\(summary.listState)",
                "contact[\(summary.handle)].badgeStatus=\(summary.badgeStatus ?? "none")",
                "contact[\(summary.handle)].listSection=\(summary.listSection)",
                "contact[\(summary.handle)].presencePill=\(summary.presencePill)",
                "contact[\(summary.handle)].beepThreadProjection=\(summary.beepThreadProjection)",
                "contact[\(summary.handle)].hasIncomingBeep=\(summary.hasIncomingBeep)",
                "contact[\(summary.handle)].hasOutgoingBeep=\(summary.hasOutgoingBeep)",
                "contact[\(summary.handle)].requestCount=\(summary.requestCount)",
                "contact[\(summary.handle)].incomingBeepCount=\(summary.incomingBeepCount.map(String.init(describing:)) ?? "none")",
                "contact[\(summary.handle)].outgoingBeepCount=\(summary.outgoingBeepCount.map(String.init(describing:)) ?? "none")",
            ]
        }
        return (coreLines + contactLines).joined(separator: "\n")
    }

    var diagnosticsTinySnapshot: String {
        let fields = diagnosticsStateFields
        let keys = [
            "selectedContact",
            "selectedConversationPhase",
            "selectedConversationStatus",
            "selectedConversationRelationship",
            "pendingAction",
            "activeChannelId",
            "isJoined",
            "isTransmitting",
            "isPTTAudioSessionActive",
            "mediaState",
            "mediaSessionContact",
            "backendChannelStatus",
            "backendReadiness",
            "backendSelfJoined",
            "backendPeerJoined",
            "backendPeerDeviceConnected",
            "remoteAudioReadiness",
            "remoteWakeCapability",
            "incomingWakeActivationState",
            "backendStatus",
            "status",
        ]
        return keys.compactMap { key -> String? in
            guard let value = fields[key] else { return nil }
            return "\(key)=\(Self.truncatedDiagnosticsValue(value, limit: 240))"
        }
        .joined(separator: "\n")
    }

    private static func truncatedDiagnosticsValue(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "...<truncated>"
    }

    var diagnosticsTranscript: String {
        diagnosticsTranscriptText()
    }

    func diagnosticsEnvelope(
        appVersion: String,
        scenarioName: String? = nil,
        scenarioRunID: String? = nil,
        compact: Bool = false,
        minimal: Bool = false,
        engineTraceStepLimit: Int? = nil
    ) -> DiagnosticsEnvelope {
        let invariantViolations = minimal
            ? Array(diagnostics.invariantViolations.prefix(4))
            : compact
                ? Array(diagnostics.invariantViolations.prefix(12))
                : diagnostics.invariantViolations
        let stateCaptures = minimal
            ? Array(diagnostics.stateCaptures.prefix(3))
            : compact
                ? Array(diagnostics.stateCaptures.prefix(12))
                : diagnostics.stateCaptures
        let reducerTransitionReports = minimal
            ? Array(diagnostics.reducerTransitionReports.prefix(6))
            : compact
                ? Array(diagnostics.reducerTransitionReports.prefix(24))
                : diagnostics.reducerTransitionReports
        let traceStepLimit = engineTraceStepLimit ?? (minimal ? 48 : compact ? 120 : nil)
        let trace = traceStepLimit.flatMap { compactEngineTrace(maxSteps: $0) } ?? engineTrace
        return DiagnosticsEnvelope(
            schemaVersion: 1,
            appVersion: appVersion,
            deviceId: backendServices?.deviceID ?? backendConfig?.deviceID ?? "unconfigured",
            handle: currentDevUserHandle,
            scenarioName: scenarioName,
            scenarioRunId: scenarioRunID,
            timestamp: .now,
            projection: stateMachineProjection,
            directQuic: selectedDirectQuicDiagnosticsSummary,
            invariantViolations: invariantViolations,
            stateCaptures: stateCaptures,
            reducerTransitionReports: reducerTransitionReports,
            engineTrace: trace
        )
    }

    func diagnosticsStructuredEnvelopeJSON(
        appVersion: String,
        scenarioName: String? = nil,
        scenarioRunID: String? = nil,
        compact: Bool = false,
        minimal: Bool = false,
        engineTraceStepLimit: Int? = nil
    ) throws -> String {
        try Self.structuredDiagnosticsEnvelopeJSON(
            diagnosticsEnvelope(
                appVersion: appVersion,
                scenarioName: scenarioName,
                scenarioRunID: scenarioRunID,
                compact: compact,
                minimal: minimal,
                engineTraceStepLimit: engineTraceStepLimit
            )
        )
    }

    private func compactEngineTrace(maxSteps: Int) -> EngineTrace? {
        let trace = engineTrace
        guard maxSteps > 0 else { return nil }
        guard trace.steps.count > maxSteps else { return trace }
        let removedStepCount = trace.steps.count - maxSteps
        let retainedSteps = Array(trace.steps.suffix(maxSteps))
        let initialState = trace.steps[removedStepCount - 1].resultingState
        return EngineTrace(
            schemaVersion: trace.schemaVersion,
            localDeviceID: trace.localDeviceID,
            initialState: initialState,
            steps: retainedSteps
        )
    }

    static func structuredDiagnosticsEnvelopeJSON(_ envelope: DiagnosticsEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    func diagnosticsTranscriptText(
        structuredEnvelopeJSON: String? = nil,
        includePersistedLogTail: Bool = false,
        compact: Bool = false,
        minimal: Bool = false,
        tiny: Bool = false,
        includeSnapshot: Bool = true
    ) -> String {
        diagnostics.exportText(
            snapshot: includeSnapshot ? diagnosticsSnapshot : nil,
            structuredEnvelopeJSON: structuredEnvelopeJSON,
            includePersistedLogTail: includePersistedLogTail,
            stateCaptureExportLimit: tiny ? 0 : minimal ? 3 : compact ? 12 : nil,
            invariantViolationExportLimit: tiny ? 2 : minimal ? 4 : compact ? 12 : nil,
            reducerTransitionReportExportLimit: tiny ? 0 : minimal ? 6 : compact ? 24 : nil,
            entryExportLimit: tiny ? 4 : minimal ? 4 : compact ? 40 : nil,
            metadataPairExportLimit: tiny ? 8 : nil,
            metadataValueExportLimit: tiny ? 160 : nil,
            lineExportLimit: tiny ? 1_200 : nil
        )
    }

    func captureDiagnosticsState(_ reason: String) {
        diagnostics.captureState(
            reason: reason,
            fields: diagnosticsStateFields,
            devicePTTProjection: stateMachineProjection.devicePTT,
            uiProjection: uiProjectionDiagnostics
        )
        publishDiagnosticsStateTelemetry(reason: reason)
        scheduleAutomaticDiagnosticsPublish(trigger: reason)
    }

    func updateUIProjectionDiagnostics(_ projection: UIProjectionDiagnostics, reason: String) {
        guard uiProjectionDiagnostics != projection else { return }
        uiProjectionDiagnostics = projection
        captureDiagnosticsState(reason)
    }

    private func publishDiagnosticsStateTelemetry(reason: String) {
#if DEBUG
        guard stateCaptureTelemetryEnabled else { return }
        sendTelemetryEvent(
            eventName: "ios.diagnostics.state_capture",
            severity: .debug,
            phase: diagnosticsStateFields["selectedConversationPhase"],
            reason: reason,
            message: statusMessage,
            metadata: diagnosticsStateTelemetryMetadata()
        )
#endif
    }

    private func diagnosticsStateTelemetryMetadata() -> [String: String] {
        var metadata: [String: String] = [
            "backendStatus": backendStatusMessage,
            "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
            "primaryStatus": statusMessage,
            "systemSession": String(describing: systemSessionState),
        ]
        for key in [
            "selectedContact",
            "selectedConversationPhaseDetail",
            "selectedConversationRelationship",
            "isJoined",
            "isTransmitting",
            "transmitPhase",
            "transmitPressActive",
            "transmitExplicitStopRequested",
            "transmitSystemTransmitting",
            "backendChannelStatus",
            "backendReadiness",
            "backendSelfJoined",
            "backendPeerJoined",
            "backendPeerDeviceConnected",
            "remoteAudioReadiness",
            "remoteWakeCapabilityKind",
        ] {
            if let value = diagnosticsStateFields[key] {
                metadata[key] = value
            }
        }
        return metadata
    }

    func scheduleAutomaticDiagnosticsPublish(trigger: String) {
#if DEBUG
        guard automaticDiagnosticsPublishEnabled else { return }
        guard backendServices != nil else { return }
        diagnosticsAutoPublishPendingTrigger = trigger
        automaticDiagnosticsPublishStatusText = "Diagnostics queued"
        guard diagnosticsAutoPublishTask == nil else { return }
        diagnosticsAutoPublishTask = Task { @MainActor [weak self] in
            while true {
                do {
                    try await Task.sleep(nanoseconds: self?.diagnosticsAutoPublishDelayNanoseconds ?? 8_000_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }

                guard let self, !Task.isCancelled else { return }
                let publishTrigger = self.diagnosticsAutoPublishPendingTrigger ?? trigger
                self.diagnosticsAutoPublishPendingTrigger = nil
                if let deferralReason = self.automaticDiagnosticsPublishDeferralReason {
                    self.diagnosticsAutoPublishPendingTrigger = publishTrigger
                    self.automaticDiagnosticsPublishStatusText = deferralReason.statusText
#if DEBUG
                    print(
                        "diagnostics auto publish deferred",
                        "trigger=\(publishTrigger)",
                        "reason=\(deferralReason.rawValue)"
                    )
#endif
                    self.diagnostics.record(
                        .app,
                        level: .debug,
                        message: "Deferred automatic diagnostics publish during live media",
                        metadata: [
                            "trigger": publishTrigger,
                            "reason": deferralReason.rawValue,
                        ]
                    )
                    continue
                }

                do {
                    let startedAt = Date()
                    self.automaticDiagnosticsPublishStatusText = "Diagnostics uploading"
#if DEBUG
                    print("diagnostics auto publish started", "trigger=\(publishTrigger)")
#endif
                    let result = try await self.publishDiagnosticsIfPossible(
                        trigger: "automatic:\(publishTrigger)",
                        recordSuccess: false,
                        preferredUploadMode: self.automaticDiagnosticsPublishPreferredUploadMode
                    )
#if DEBUG
                    print(
                        "diagnostics auto publish succeeded",
                        "trigger=\(publishTrigger)",
                        "duration=\(Date().timeIntervalSince(startedAt))"
                    )
#endif
                    var metadata = [
                        "deviceId": result.response.report.deviceId,
                        "uploadedAt": result.response.report.uploadedAt,
                        "uploadMode": result.uploadMode.rawValue,
                        "requestBodySizeBytes": String(result.requestBodySizeBytes),
                    ]
                    if let engineTraceStepLimit = result.engineTraceStepLimit {
                        metadata["engineTraceStepLimit"] = String(engineTraceStepLimit)
                    }
                    if let fallbackError = result.fallbackFromFullError {
                        metadata["fallbackFromFullError"] = fallbackError
                    }
                    self.automaticDiagnosticsPublishStatusText =
                        "Diagnostics uploaded \(result.uploadMode.rawValue) - \(self.diagnosticsUploadSizeText(result.requestBodySizeBytes))"
                    self.sendTelemetryEvent(
                        eventName: "ios.diagnostics.auto_publish_succeeded",
                        severity: .debug,
                        reason: publishTrigger,
                        message: "Automatic diagnostics publish succeeded",
                        metadata: metadata
                    )
                } catch let error as AutomaticDiagnosticsPublishDeferredError {
                    self.diagnosticsAutoPublishPendingTrigger = publishTrigger
                    self.automaticDiagnosticsPublishStatusText = error.reason.statusText
                    continue
                } catch is CancellationError {
                    return
                } catch {
#if DEBUG
                    print(
                        "diagnostics auto publish failed",
                        "trigger=\(publishTrigger)",
                        "error=\(error.localizedDescription)"
                    )
#endif
                    self.automaticDiagnosticsPublishStatusText = "Diagnostics upload failed"
                    self.diagnostics.record(
                        .app,
                        level: .notice,
                        message: "Automatic diagnostics publish failed",
                        metadata: [
                            "trigger": publishTrigger,
                            "uploadMode": self.automaticDiagnosticsPublishPreferredUploadMode.rawValue,
                            "error": error.localizedDescription,
                        ]
                    )
                    self.sendTelemetryEvent(
                        eventName: "ios.diagnostics.auto_publish_failed",
                        severity: .notice,
                        reason: publishTrigger,
                        message: "Automatic diagnostics publish failed",
                        metadata: [
                            "uploadMode": self.automaticDiagnosticsPublishPreferredUploadMode.rawValue,
                            "error": error.localizedDescription,
                        ]
                    )
                }

                if self.diagnosticsAutoPublishPendingTrigger == nil {
                    self.diagnosticsAutoPublishTask = nil
                    return
                }
            }
        }
#endif
    }

    var shouldDeferAutomaticDiagnosticsPublishForLiveMedia: Bool {
        automaticDiagnosticsPublishDeferralReason != nil
    }

    var automaticDiagnosticsPublishPreferredUploadMode: DiagnosticsUploadMode {
        .tiny
    }

    var automaticDiagnosticsPublishDeferralReason: AutomaticDiagnosticsPublishDeferralReason? {
        if uiProjectionDiagnostics.callScreenVisible {
            return .callScreen
        }

        if hasPendingBeginOrActiveTransmit
            || isTransmitting
            || transmitCoordinator.state.isPressingTalk
            || pttCoordinator.state.isTransmitting
            || isPTTAudioSessionActive {
            return .liveMedia
        }

        if receiveExecutionCoordinator.state.remoteActivityByContactID.values.contains(
            where: { $0.phase.isPeerTransmitting }
        ) {
            return .liveMedia
        }

        return pttWakeRuntime.pendingIncomingPush != nil ? .liveMedia : nil
    }

    func cancelAutomaticDiagnosticsPublish() {
        diagnosticsAutoPublishTask?.cancel()
        diagnosticsAutoPublishTask = nil
        diagnosticsAutoPublishPendingTrigger = nil
        automaticDiagnosticsPublishStatusText = nil
    }

    private func diagnosticsUploadSizeText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    func replaceDisconnectRecoveryTask(with task: Task<Void, Never>?) {
        disconnectRecoveryTask?.cancel()
        disconnectRecoveryTask = task
    }

    var selectedChannelState: TurboChannelStateResponse? {
        guard let selectedContactId else { return nil }
        return channelStateByContactID[selectedContactId]
    }

    var systemSessionState: SystemPTTSessionState {
        pttCoordinator.state.systemSessionState
    }

    func canTransmitNow(for contactID: UUID) -> Bool {
        guard selectedContactId == contactID else { return false }
        guard !remoteReceiveBlocksLocalTransmit(for: contactID) else { return false }
        return selectedConversationState(for: contactID).canTransmitNow
    }

    func canBeginTransmit(for contactID: UUID) -> Bool {
        guard selectedContactId == contactID else { return false }
        guard !remoteReceiveBlocksLocalTransmit(for: contactID) else { return false }
        return selectedConversationState(for: contactID).allowsHoldToTalk
    }

    @discardableResult
    func receiveRemoteAudioChunk(_ payload: String) async -> Bool {
        guard let session = mediaServices.session() else { return false }
        return await receiveRemoteAudioChunkOffMain(
            session: session,
            payload: payload,
            playbackProfile: .lowLatency
        )
    }

    @discardableResult
    func receiveRemoteAudioChunk(
        _ payload: String,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) async -> Bool {
        let transportPolicy = mediaTransportPolicy(for: incomingAudioTransport)
        if mediaRuntime.shouldReportMediaTransportPolicy(transportPolicy) {
            diagnostics.record(
                .media,
                message: "Selected media transport policy",
                metadata: [
                    "transport": incomingAudioTransport.diagnosticsValue,
                    "policy": transportPolicy.rawValue,
                    "playbackProfile": String(describing: transportPolicy.playbackProfile),
                ]
            )
        }
        guard let session = mediaServices.session() else { return false }
        return await receiveRemoteAudioChunkOffMain(
            session: session,
            payload: payload,
            playbackProfile: transportPolicy.playbackProfile
        )
    }

    private func receiveRemoteAudioChunkOffMain(
        session: any MediaSession,
        payload: String,
        playbackProfile: MediaSessionPlaybackProfile
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            await session.receiveRemoteAudioChunk(
                payload,
                playbackProfile: playbackProfile
            )
        }.value
    }

    func mediaTransportPolicy(
        for incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> MediaTransportPolicy {
        let applicationState = currentApplicationState()
        if applicationState != .active, !isPTTAudioSessionActive {
            return .wakeBackgroundContinuity
        }
        switch incomingAudioTransport {
        case .directQuic:
            return .directLowLatency
        case .mediaRelayPacket:
            return .fastRelayBalanced
        case .mediaRelayTcp:
            return .websocketContinuity
        case .relayWebSocket:
            return .websocketContinuity
        }
    }

    func mediaTransportPolicyForOutgoingAudio(for contactID: UUID) -> MediaTransportPolicy {
        if shouldUseWakeBackgroundContinuityForOutgoingAudio(for: contactID) {
            return .wakeBackgroundContinuity
        }
        if shouldUseDirectQuicTransport(for: contactID) {
            if hasConfiguredOutgoingAudioContinuityFallback() {
                return .fastRelayBalanced
            }
            return .directLowLatency
        }
        if mediaTransportPathState == .fastRelay {
            return .fastRelayBalanced
        }
        return .websocketContinuity
    }

    func hasConfiguredOutgoingAudioContinuityFallback() -> Bool {
        guard !isDirectPathRelayOnlyForced else { return false }
        guard !TurboMediaRelayDebugOverride.isForced() else { return false }
        guard TurboMediaRelayDebugOverride.isEnabled() else { return false }
        return TurboMediaRelayDebugOverride.config()?.isConfigured == true
    }

    func shouldUseWakeBackgroundContinuityForOutgoingAudio(for contactID: UUID) -> Bool {
        if currentApplicationState() != .active {
            return true
        }
        guard let channel = selectedChannelSnapshot(for: contactID),
              !channel.remoteAudioReadyForLiveTransmit else {
            return false
        }
        if case .wakeCapable = channel.remoteWakeCapability {
            return true
        }
        return false
    }

    func outboundOpusEncodingPolicy(for contactID: UUID) -> OpusVoiceEncodingPolicy {
        mediaTransportPolicyForOutgoingAudio(for: contactID).opusEncodingPolicy(
            observedPacketLossPercent: mediaRuntime.observedPacketLossPercent(for: contactID)
        )
    }

    func refreshMicrophonePermission() {
        microphonePermission = AVAudioApplication.shared.recordPermission
    }

    var microphonePermissionStatusText: String {
        switch microphonePermission {
        case .granted:
            return "Microphone enabled"
        case .denied:
            return "Microphone denied"
        case .undetermined:
            return "Microphone not requested"
        @unknown default:
            return "Microphone unknown"
        }
    }

    var needsMicrophonePermission: Bool {
        microphonePermission != .granted
    }

    func requestMicrophonePermission() async {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    self?.refreshMicrophonePermission()
                    self?.diagnostics.record(
                        .app,
                        message: "Microphone permission resolved",
                        metadata: ["granted": granted ? "true" : "false"]
                    )
                    self?.captureDiagnosticsState("microphone-permission")
                    continuation.resume()
                }
            }
        }
    }

    private func registerAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruptionNotification(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChangeNotification(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionMediaServicesResetNotification(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    private func registerApplicationLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActiveNotification(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillResignActiveNotification(_:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidEnterBackgroundNotification(_:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProtectedDataWillBecomeUnavailableNotification(_:)),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )
    }

    @objc private func handleAudioSessionInterruptionNotification(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let rawType = (info[AVAudioSessionInterruptionTypeKey] as? UInt).map(String.init) ?? "unknown"
        let rawOptions = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(String.init) ?? "0"
        diagnostics.record(
            .media,
            message: "Audio session interruption notification",
            metadata: audioSessionDiagnostics().merging(
                [
                    "type": rawType,
                    "options": rawOptions
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
    }

    @objc private func handleAudioSessionRouteChangeNotification(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let rawReason = (info[AVAudioSessionRouteChangeReasonKey] as? UInt).map(String.init) ?? "unknown"
        applyPreferredAudioOutputRouteIfPossible()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if shouldDeferAudioRouteRefreshDuringLiveReceive() {
                recordDeferredLiveReceiveAudioRouteRefresh(
                    source: "audio-route-notification",
                    contactID: nil,
                    reason: rawReason
                )
            } else {
                await mediaServices.session()?.audioRouteDidChange()
            }
            await syncConversationParticipantTelemetryIfNeeded(reason: .audioRouteChange)
        }
        diagnostics.record(
            .media,
            message: "Audio session route change notification",
            metadata: audioSessionDiagnostics().merging(
                ["reason": rawReason],
                uniquingKeysWith: { _, new in new }
            )
        )
    }

    @objc private func handleAudioSessionMediaServicesResetNotification(_ notification: Notification) {
        let _ = notification
        diagnostics.record(
            .media,
            message: "Audio session media services were reset",
            metadata: audioSessionDiagnostics()
        )
    }

    @objc private func handleApplicationDidBecomeActiveNotification(_ notification: Notification) {
        let _ = notification
        diagnostics.record(
            .app,
            message: "Application became active",
            metadata: [:]
        )
        Task { @MainActor [weak self] in
            await self?.handleApplicationDidBecomeActive()
        }
    }

    func handleApplicationDidBecomeActive() async {
        syncEngineLifecycle(.active, reason: "application-did-become-active")
        lastLifecyclePresenceTransitionKind = nil
        lastLifecyclePresenceTransitionAt = nil
        lifecyclePresenceTransitionInFlightKind = nil
        backendServices?.resumeWebSocket()
        await publishForegroundPresenceTransition(reason: "application-did-become-active")
        updateAutomaticAudioRouteMonitoring(reason: "application-became-active")
        clearBeepNotifications()
        reconcileIncomingBeepSurface(
            applicationState: .active,
            allowsSelectedContact: true,
            allowsAlreadySurfacedBeep: true
        )
        await resumeBufferedWakePlaybackIfNeeded(
            reason: "application-became-active",
            applicationState: .active
        )
        await resumeInteractiveAudioPrewarmIfNeeded(
            reason: "application-became-active",
            applicationState: .active
        )
        if let selectedContactId {
            await prewarmForegroundTalkPathIfNeeded(
                for: selectedContactId,
                reason: "application-became-active"
            )
        }
        await backendSyncCoordinator.handle(.pollRequested(selectedContactID: selectedContactId))
    }

    func publishForegroundPresenceTransition(reason: String) async {
        guard shouldPublishForegroundPresence(applicationState: .active),
              let backend = backendServices else {
            return
        }
        do {
            _ = try await backend.foregroundPresence()
            backendRuntime.markPresenceHeartbeatSent()
            diagnostics.record(
                .backend,
                message: "Foreground presence publish succeeded",
                metadata: ["reason": reason]
            )
        } catch {
            diagnostics.record(
                .backend,
                level: .error,
                message: "Foreground presence publish failed",
                metadata: [
                    "error": error.localizedDescription,
                    "reason": reason,
                ]
            )
        }
    }

    private func lifecyclePresenceTransitionKindForBackground() -> LifecyclePresenceTransitionKind {
        if shouldPublishActiveSessionPresenceDuringBackground(applicationState: .background) {
            return .activeSession
        }
        return shouldMaintainBackgroundControlPlane(applicationState: .background)
            ? .background
            : .offline
    }

    private func shouldSkipLifecyclePresenceTransition(_ kind: LifecyclePresenceTransitionKind) -> Bool {
        if lifecyclePresenceTransitionInFlightKind == kind {
            return true
        }
        guard lastLifecyclePresenceTransitionKind == kind,
              let lastLifecyclePresenceTransitionAt else {
            return false
        }
        return Date().timeIntervalSince(lastLifecyclePresenceTransitionAt)
            < lifecyclePresenceTransitionDeduplicationWindowSeconds
    }

    private func noteLifecyclePresenceTransition(_ kind: LifecyclePresenceTransitionKind) {
        lastLifecyclePresenceTransitionKind = kind
        lastLifecyclePresenceTransitionAt = Date()
    }

    func publishLifecyclePresenceTransitionIfNeeded(reason: String) async {
        let transitionKind = lifecyclePresenceTransitionKindForBackground()
        let transitionKindLabel: String = {
            switch transitionKind {
            case .activeSession:
                return "active-session"
            case .background:
                return "background"
            case .offline:
                return "offline"
            }
        }()
        guard !shouldSkipLifecyclePresenceTransition(transitionKind) else {
            diagnostics.record(
                .backend,
                message: "Skipped duplicate lifecycle presence transition",
                metadata: [
                    "reason": reason,
                    "kind": transitionKindLabel,
                ]
            )
            return
        }
        lifecyclePresenceTransitionInFlightKind = transitionKind
        diagnostics.record(
            .backend,
            message: "Lifecycle presence publish started",
            metadata: [
                "reason": reason,
                "kind": transitionKindLabel,
            ]
        )
        var didPublishTransition = false
        defer {
            lifecyclePresenceTransitionInFlightKind = nil
            if didPublishTransition {
                noteLifecyclePresenceTransition(transitionKind)
            }
        }

        switch transitionKind {
        case .activeSession:
            guard backgroundActiveSessionPresenceHandler != nil || backendServices != nil else { return }
            await performProtectedBackgroundHandoff(named: "active-session-presence") { [weak self] in
                guard let self else { return }
                if let backgroundActiveSessionPresenceHandler {
                    await backgroundActiveSessionPresenceHandler()
                    didPublishTransition = true
                    diagnostics.record(
                        .backend,
                        message: "Lifecycle presence publish succeeded",
                        metadata: [
                            "reason": reason,
                            "kind": transitionKindLabel,
                        ]
                    )
                    return
                }
                guard let backend = backendServices else { return }
                do {
                    _ = try await backend.foregroundPresence()
                    didPublishTransition = true
                    diagnostics.record(
                        .backend,
                        message: "Lifecycle presence publish succeeded",
                        metadata: [
                            "reason": reason,
                            "kind": transitionKindLabel,
                        ]
                    )
                } catch {
                    diagnostics.record(
                        .backend,
                        level: .error,
                        message: "Active session presence publish failed",
                        metadata: [
                            "error": error.localizedDescription,
                            "reason": reason,
                        ]
                    )
                }
            }
        case .background:
            guard backgroundSessionPresenceHandler != nil || backendServices != nil else { return }
            await performProtectedBackgroundHandoff(named: "background-presence") { [weak self] in
                guard let self else { return }
                if let backgroundSessionPresenceHandler {
                    await backgroundSessionPresenceHandler()
                    didPublishTransition = true
                    diagnostics.record(
                        .backend,
                        message: "Lifecycle presence publish succeeded",
                        metadata: [
                            "reason": reason,
                            "kind": transitionKindLabel,
                        ]
                    )
                    return
                }
                guard let backend = backendServices else { return }
                do {
                    _ = try await backend.backgroundPresence()
                    didPublishTransition = true
                    diagnostics.record(
                        .backend,
                        message: "Lifecycle presence publish succeeded",
                        metadata: [
                            "reason": reason,
                            "kind": transitionKindLabel,
                        ]
                    )
                } catch {
                    diagnostics.record(
                        .backend,
                        level: .error,
                        message: "Background presence publish failed",
                        metadata: [
                            "error": error.localizedDescription,
                            "reason": reason,
                        ]
                    )
                }
            }
        case .offline:
            guard backgroundOfflinePresenceHandler != nil || backendServices != nil else { return }
            await performProtectedBackgroundHandoff(named: "offline-presence") { [weak self] in
                guard let self else { return }
                if let backgroundOfflinePresenceHandler {
                    await backgroundOfflinePresenceHandler()
                    didPublishTransition = true
                    diagnostics.record(
                        .backend,
                        message: "Lifecycle presence publish succeeded",
                        metadata: [
                            "reason": reason,
                            "kind": transitionKindLabel,
                        ]
                    )
                    return
                }
                guard let backend = backendServices else { return }
                do {
                    _ = try await backend.offlinePresence()
                    didPublishTransition = true
                    diagnostics.record(
                        .backend,
                        message: "Lifecycle presence publish succeeded",
                        metadata: [
                            "reason": reason,
                            "kind": transitionKindLabel,
                        ]
                    )
                } catch {
                    diagnostics.record(
                        .backend,
                        level: .error,
                        message: "Offline presence publish failed",
                        metadata: [
                            "error": error.localizedDescription,
                            "reason": reason,
                        ]
                    )
                }
            }
        }
    }

    func handleApplicationDidEnterBackground() async {
        syncEngineLifecycle(.background, reason: "application-did-enter-background")
        let shouldPreserveJoinedSession =
            shouldMaintainBackgroundControlPlane(applicationState: .background)
        let shouldPreserveLiveWebSocket =
            shouldPreserveBackgroundWebSocketForLivePTT(applicationState: .background)

        if shouldPreserveLiveWebSocket {
            diagnostics.record(
                .websocket,
                message: "Preserving WebSocket during live background PTT flow",
                metadata: [
                    "hasPendingBeginOrActiveTransmit": String(hasPendingBeginOrActiveTransmit),
                    "hasActiveTransmitOrMediaSession": String(hasActiveTransmitOrMediaSession),
                    "isTransmitting": String(isTransmitting),
                    "systemIsTransmitting": String(pttCoordinator.state.isTransmitting),
                    "pendingWake": String(pttWakeRuntime.pendingIncomingPush != nil),
                ]
            )
            backendServices?.resumeWebSocket()
        } else if let backgroundWebSocketSuspendHandler {
            backgroundWebSocketSuspendHandler()
        } else {
            backendServices?.suspendWebSocket()
        }

        let _ = shouldPreserveJoinedSession
        await publishLifecyclePresenceTransitionIfNeeded(reason: "application-did-enter-background")
    }

    func scheduleApplicationWillResignActiveHandling() {
        syncEngineLifecycle(.inactive, reason: "application-will-resign-active")
        let endLease = beginProtectedBackgroundActivity(named: "application-will-resign-active")
        Task { @MainActor [weak self, endLease] in
            defer { endLease() }
            guard let self else { return }
            await self.publishLifecyclePresenceTransitionIfNeeded(
                reason: "application-will-resign-active"
            )
            await self.reconcileIdleTransportForBackgroundTransition(
                reason: "application-will-resign-active",
                applicationState: .inactive
            )
            await self.suspendForegroundMediaForBackgroundTransition(
                reason: "application-will-resign-active",
                applicationState: .inactive
            )
        }
    }

    func scheduleApplicationDidEnterBackgroundHandling() {
        let endLease = beginProtectedBackgroundActivity(named: "application-did-enter-background")
        Task { @MainActor [weak self, endLease] in
            defer { endLease() }
            guard let self else { return }
            await self.reconcileIdleTransportForBackgroundTransition(
                reason: "application-did-enter-background",
                applicationState: .background
            )
            await self.suspendForegroundMediaForBackgroundTransition(
                reason: "application-did-enter-background",
                applicationState: .background
            )
            await self.handleApplicationDidEnterBackground()
        }
    }

    @objc private func handleApplicationWillResignActiveNotification(_ notification: Notification) {
        let _ = notification
        diagnostics.record(
            .app,
            message: "Application will resign active",
                metadata: [:]
        )
        cancelActiveTransmitForLifecycleInterruption(reason: "application-will-resign-active")
        if shouldPreserveLiveCallForProximityInactiveTransition(applicationState: .inactive) {
            diagnostics.record(
                .media,
                message: "Preserving live call during proximity inactive transition",
                metadata: [
                    "activeChannelId": activeChannelId?.uuidString ?? "none",
                    "isNearEar": String(isPhoneNearEar || UIDevice.current.proximityState),
                    "proximityMonitoring": String(proximityMonitoringIsActive),
                ]
            )
            return
        }
        stopAutomaticAudioRouteMonitoring(reason: "application-will-resign-active")
        retireIdleDirectQuicForBackgroundTransitionImmediately(
            reason: "application-will-resign-active",
            applicationState: .inactive
        )
        scheduleApplicationWillResignActiveHandling()
    }

    @objc private func handleApplicationDidEnterBackgroundNotification(_ notification: Notification) {
        let _ = notification
        diagnostics.record(
            .app,
            message: "Application entered background",
                metadata: [:]
        )
        cancelActiveTransmitForLifecycleInterruption(reason: "application-did-enter-background")
        stopAutomaticAudioRouteMonitoring(reason: "application-did-enter-background")
        retireIdleDirectQuicForBackgroundTransitionImmediately(
            reason: "application-did-enter-background",
            applicationState: .background
        )
        scheduleApplicationDidEnterBackgroundHandling()
    }

    @objc private func handleProtectedDataWillBecomeUnavailableNotification(_ notification: Notification) {
        let _ = notification
        syncEngineLifecycle(.locked, reason: "protected-data-will-become-unavailable")
        diagnostics.record(
            .app,
            message: "Protected data will become unavailable",
            metadata: [:]
        )
        Task { @MainActor [weak self] in
            await self?.publishLifecyclePresenceTransitionIfNeeded(
                reason: "protected-data-will-become-unavailable"
            )
        }
    }
}
