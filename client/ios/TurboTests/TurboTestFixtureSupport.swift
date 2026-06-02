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
extension PTTViewModel {
    func seedEngineJoinedConversationForTesting(
        contactID: UUID,
        handle: String = "@engine-test-peer",
        backendChannelID: String? = nil
    ) {
        if !contacts.contains(where: { $0.id == contactID }) {
            contacts.append(
                Contact(
                    id: contactID,
                    name: "Engine Test Peer",
                    handle: handle,
                    isOnline: true,
                    channelId: contactID,
                    backendChannelId: backendChannelID ?? contactID.uuidString,
                    remoteUserId: "engine-test-peer-user"
                )
            )
        }
        forceSyncEngineJoinedConversation(contactID: contactID, reason: "test-seed")
    }

    func clearEngineConversationForTesting() {
        sendEngineIntent(.selectFriend(nil), source: "test-clear-conversation")
    }

    func seedEngineTransmitForTesting(
        contactID: UUID,
        transmitID: String = "engine-test-transmit"
    ) {
        seedEngineJoinedConversationForTesting(contactID: contactID)
        receiveEngineEvent(
            .backend(.localTransmitObserved(EngineTransmitID(transmitID))),
            source: "test-seed-transmit"
        )
    }

    func seedEngineActiveTransmitForTesting(
        contactID: UUID,
        channelID: String,
        localDeviceID: String,
        peerDeviceID: String,
        peerUserID: String = "peer-user",
        transmitID: String? = nil,
        transport: EngineTransportPath = .relayWebSocket
    ) {
        if !contacts.contains(where: { $0.id == contactID }) {
            contacts.append(
                Contact(
                    id: contactID,
                    name: "Engine Test Peer",
                    handle: "@engine-test-peer",
                    isOnline: true,
                    channelId: contactID,
                    backendChannelId: channelID,
                    remoteUserId: peerUserID
                )
            )
        }
        let joined = JoinedConversationEvidence(
            friend: SelectedFriendEvidence(contactID: ContactID(contactID.uuidString), handle: "@engine-test-peer"),
            channelID: EngineChannelID(channelID),
            localDeviceID: EngineDeviceID(localDeviceID),
            peerDevice: .ready(PeerDeviceEvidence(deviceID: EngineDeviceID(peerDeviceID))),
            receiverAddressability: .foreground(PeerDeviceEvidence(deviceID: EngineDeviceID(peerDeviceID))),
            readiness: .ready(
                JoinedReadinessEvidence(
                    backendMembershipObserved: BackendMembershipEvidence(
                        channelID: EngineChannelID(channelID),
                        localDeviceID: EngineDeviceID(localDeviceID),
                        peerDeviceID: EngineDeviceID(peerDeviceID),
                        observedAtTick: 1
                    ),
                    transport: transport
                )
            )
        )
        receiveEngineEvent(.backend(.joined(joined)), source: "test-seed-active-transmit-joined")
        receiveEngineEvent(
            .backend(.localTransmitObserved(EngineTransmitID(transmitID ?? "local-\(channelID)"))),
            source: "test-seed-active-transmit"
        )
    }
}

@MainActor
func makeDirectQuicNominatedPath(
    attemptID: String = "attempt-1"
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
func seedActiveDirectQuicNetworkMigrationSubject(
    _ viewModel: PTTViewModel,
    contactID: UUID,
    channelID: String = "channel-1",
    attemptID: String = "attempt-1",
    peerDeviceID: String = "peer-device"
) {
    viewModel.replaceBackendConfig(with: makeUnreachableBackendConfig())
    viewModel.applicationStateOverride = .active
    viewModel.selectedContactId = contactID
    viewModel.contacts = [
        Contact(
            id: contactID,
            name: "Peer",
            handle: "@peer",
            isOnline: true,
            channelId: contactID,
            backendChannelId: channelID,
            remoteUserId: "peer-user"
        ),
    ]
    viewModel.seedEngineActiveTransmitForTesting(
        contactID: contactID,
        channelID: channelID,
        localDeviceID: "test-device",
        peerDeviceID: peerDeviceID,
        transport: .directQuic
    )
    viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
    _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
        contactID: contactID,
        channelID: channelID,
        attemptID: attemptID,
        peerDeviceID: peerDeviceID,
        networkPathGeneration: viewModel.mediaRuntime.networkPathGeneration
    )
    _ = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
        for: contactID,
        attemptID: attemptID,
        nominatedPath: makeDirectQuicNominatedPath(attemptID: attemptID)
    )
    viewModel.mediaRuntime.updateTransportPathState(.direct)
}

@MainActor
func makeIncomingBeepAcceptRouteFixture() -> (
    viewModel: PTTViewModel,
    client: TurboBackendClient,
    contact: Contact,
    beep: TurboBeepResponse,
    notificationUserInfo: [AnyHashable: Any]
) {
    let beep = makeBeep(
        direction: "incoming",
        beepId: "beep-1",
        fromHandle: "@avery",
        toHandle: "@self"
    )
    let contact = Contact(
        id: UUID(),
        name: "Avery",
        handle: "@avery",
        isOnline: true,
        channelId: UUID(),
        backendChannelId: beep.channelId,
        remoteUserId: beep.fromUserId
    )
    let client = TurboBackendClient(
        config: TurboBackendConfig(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            devUserHandle: "@self",
            deviceID: "self-device"
        )
    )
    client.setRuntimeConfigForTesting(
        TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
    )
    client.enableSentSignalCaptureForTesting()

    let viewModel = PTTViewModel()
    viewModel.applyAuthenticatedBackendSession(
        client: client,
        userID: "user-self",
        mode: "cloud"
    )
    viewModel.selectedContactPrewarmPipelineEnabled = true
    viewModel.applicationStateOverride = .active
    viewModel.contacts = [contact]
    viewModel.backendSyncCoordinator.send(
        .beepsUpdated(
            incoming: [BackendBeepUpdate(contactID: contact.id, beep: beep)],
            outgoing: [],
            now: .now
        )
    )

    return (
        viewModel: viewModel,
        client: client,
        contact: contact,
        beep: beep,
        notificationUserInfo: [
            "event": TurboNotificationCategory.beepEvent,
            "fromHandle": contact.handle,
            "beepId": beep.beepId,
        ]
    )
}

@MainActor
func assertIncomingBeepAcceptRouteEstablishesIntentAndPrewarm(
    exercise: @MainActor (
        _ viewModel: PTTViewModel,
        _ contact: Contact,
        _ userInfo: [AnyHashable: Any]
    ) async -> Void
) async throws {
    let fixture = makeIncomingBeepAcceptRouteFixture()
    var capturedEffects: [BackendCommandEffect] = []
    var selectedContactIDsWhenJoinQueued: [UUID?] = []
    fixture.viewModel.backendCommandCoordinator.effectHandler = { effect in
        if case .join = effect {
            selectedContactIDsWhenJoinQueued.append(fixture.viewModel.selectedContactId)
        }
        capturedEffects.append(effect)
    }

    await exercise(fixture.viewModel, fixture.contact, fixture.notificationUserInfo)
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(fixture.viewModel.selectedContactId == fixture.contact.id)
    #expect(fixture.viewModel.requestedExpandedCallContactID == fixture.contact.id)
    #expect(fixture.viewModel.requestedExpandedCallSequence == 1)
    #expect(fixture.viewModel.pendingConnectAcceptedIncomingBeepContactId == fixture.contact.id)
    #expect(fixture.viewModel.selectedConversationState(for: fixture.contact.id).phase == .waitingForPeer)
    #expect(
        fixture.viewModel.diagnosticsTranscript.contains(
            "Selected contact prewarm pipeline completed"
        )
    )
    #expect(
        fixture.viewModel.diagnosticsTranscript.contains("stage=friend-prewarm-hint")
    )
    #expect(selectedContactIDsWhenJoinQueued == [fixture.contact.id])
    #expect(
        capturedEffects.contains {
            guard case let .join(request) = $0 else { return false }
            return request.contactID == fixture.contact.id
                && request.relationship == .incomingBeep(requestCount: 1)
                && request.incomingBeep?.beepId == fixture.beep.beepId
        }
    )
}


func makeChannelState(
    status: ConversationState,
    canTransmit: Bool,
    channelId: String = "channel",
    selfJoined: Bool = true,
    peerJoined: Bool = true,
    peerDeviceConnected: Bool = true,
    hasIncomingBeep: Bool = false,
    hasOutgoingBeep: Bool = false,
    activeTransmitId: String? = nil,
    stateEpoch: String? = nil
) -> TurboChannelStateResponse {
    TurboChannelStateResponse(
        channelId: channelId,
        selfUserId: "self",
        peerUserId: "peer",
        peerHandle: "@peer",
        selfOnline: true,
        peerOnline: true,
        selfJoined: selfJoined,
        peerJoined: peerJoined,
        peerDeviceConnected: peerDeviceConnected,
        hasIncomingBeep: hasIncomingBeep,
        hasOutgoingBeep: hasOutgoingBeep,
        requestCount: 0,
        activeTransmitterUserId: nil,
        activeTransmitId: activeTransmitId,
        transmitLeaseExpiresAt: nil,
        stateEpoch: stateEpoch,
        status: status.rawValue,
        canTransmit: canTransmit
    )
}

func makeChannelReadiness(
    status: TurboChannelReadinessStatus,
    selfHasActiveDevice: Bool = true,
    peerHasActiveDevice: Bool = true,
    localAudioReadiness: RemoteAudioReadinessState? = nil,
    remoteAudioReadiness: RemoteAudioReadinessState? = nil,
    localWakeCapability: RemoteWakeCapabilityState = .unavailable,
    remoteWakeCapability: RemoteWakeCapabilityState = .unavailable,
    peerDirectQuicIdentity: TurboDirectQuicPeerIdentityPayload? = nil,
    peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload? = nil,
    peerTargetDeviceId: String? = nil,
    activeTransmitId: String? = nil,
    stateEpoch: String? = nil
) -> TurboChannelReadinessResponse {
    let resolvedLocalAudioReadiness = localAudioReadiness ?? (selfHasActiveDevice ? .ready : .unknown)
    let resolvedRemoteAudioReadiness = remoteAudioReadiness ?? (peerHasActiveDevice ? .ready : .unknown)
    return TurboChannelReadinessResponse(
        channelId: "channel",
        peerUserId: "peer",
        selfHasActiveDevice: selfHasActiveDevice,
        peerHasActiveDevice: peerHasActiveDevice,
        activeTransmitterUserId: status.activeTransmitterUserId,
        activeTransmitId: activeTransmitId,
        activeTransmitExpiresAt: nil,
        stateEpoch: stateEpoch,
        status: status.kind,
        audioReadinessPayload: TurboChannelAudioReadinessPayload(
            selfReadiness: TurboAudioReadinessStatusPayload(kind: {
                switch resolvedLocalAudioReadiness {
                case .unknown:
                    return "unknown"
                case .waiting:
                    return "waiting"
                case .wakeCapable:
                    return "wake-capable"
                case .ready:
                    return "ready"
                }
            }()),
            peerReadiness: TurboAudioReadinessStatusPayload(kind: {
                switch resolvedRemoteAudioReadiness {
                case .unknown:
                    return "unknown"
                case .waiting:
                    return "waiting"
                case .wakeCapable:
                    return "wake-capable"
                case .ready:
                    return "ready"
                }
            }()),
            peerTargetDeviceId: peerTargetDeviceId ?? (peerHasActiveDevice ? "peer-device" : nil)
        ),
        wakeReadinessPayload: TurboChannelWakeReadinessPayload(
            selfWakeCapability: TurboWakeCapabilityStatusPayload(
                kind: {
                    switch localWakeCapability {
                    case .unavailable:
                        return "unavailable"
                    case .wakeCapable:
                        return "wake-capable"
                    }
                }(),
                targetDeviceId: {
                    switch localWakeCapability {
                    case .unavailable:
                        return nil
                    case .wakeCapable(let targetDeviceId):
                        return targetDeviceId
                    }
                }()
            ),
            peerWakeCapability: TurboWakeCapabilityStatusPayload(
                kind: {
                    switch remoteWakeCapability {
                    case .unavailable:
                        return "unavailable"
                    case .wakeCapable:
                        return "wake-capable"
                    }
                }(),
                targetDeviceId: {
                    switch remoteWakeCapability {
                    case .unavailable:
                        return nil
                    case .wakeCapable(let targetDeviceId):
                        return targetDeviceId
                    }
                }()
            )
        ),
        peerDirectQuicIdentity: peerDirectQuicIdentity,
        peerMediaEncryptionIdentity: peerMediaEncryptionIdentity
    )
}

func reduceSelectedConversationState(_ events: [SelectedConversationEvent]) -> SelectedConversationProjectionState {
    events.reduce(.initial) { state, event in
        SelectedConversationReducer.reduce(state: state, event: event).state
    }
}

final class LockedStringEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

@MainActor
final class BackgroundTransitionProbe {
    private(set) var events: [String] = []
    private(set) var activeSessionStarted = false
    private(set) var activeSessionCount = 0
    private(set) var backgroundStarted = false
    private(set) var backgroundCount = 0
    private(set) var backgroundTaskStarted = false
    private(set) var backgroundTaskEnded = false
    private(set) var offlineStarted = false
    private(set) var offlineCount = 0
    private(set) var suspendCount = 0

    func recordSuspend() {
        suspendCount += 1
        events.append("suspend")
    }

    func recordBackgroundTaskBegin(_ name: String) {
        backgroundTaskStarted = true
        events.append("background-task-begin:\(name)")
    }

    func recordBackgroundTaskEnd() {
        backgroundTaskEnded = true
        events.append("background-task-end")
    }

    func recordActiveSessionStart() {
        activeSessionStarted = true
        activeSessionCount += 1
        events.append("active-session-start")
    }

    func recordActiveSessionFinish() {
        events.append("active-session-finish")
    }

    func recordBackgroundStart() {
        backgroundStarted = true
        backgroundCount += 1
        events.append("background-start")
    }

    func recordBackgroundFinish() {
        events.append("background-finish")
    }

    func recordOfflineStart() {
        offlineStarted = true
        offlineCount += 1
        events.append("offline-start")
    }

    func recordOfflineFinish() {
        events.append("offline-finish")
    }
}

func makeTransmitRequest() -> TransmitRequestContext {
    TransmitRequestContext(
        contactID: UUID(),
        contactHandle: "@avery",
        backendChannelID: "channel-1",
        remoteUserID: "user-peer",
        channelUUID: UUID(),
        usesLocalHTTPBackend: false,
        backendSupportsWebSocket: true
    )
}

func captureDevicePTTDiagnosticsState(
    _ store: DiagnosticsStore,
    reason: String,
    fields: [String: String]
) {
    store.captureState(
        reason: reason,
        fields: fields,
        devicePTTProjection: makeDevicePTTDiagnosticsProjection(fields: fields)
    )
}

func makeDevicePTTDiagnosticsProjection(
    fields: [String: String]
) -> DevicePTTDiagnosticsProjection {
    DevicePTTDiagnosticsProjection(
        selectedContactID: optionalDiagnosticsString(fields["selectedContactID"]),
        selectedHandle: optionalDiagnosticsString(fields["selectedContact"]),
        selectedConversationPhase: fields["selectedConversationPhase"] ?? "none",
        selectedConversationPhaseDetail: fields["selectedConversationPhaseDetail"] ?? "none",
        selectedConversationRelationship: fields["selectedConversationRelationship"] ?? "none",
        selectedConversationCanTransmit: diagnosticsBool(fields["selectedConversationCanTransmit"]) ?? false,
        selectedConversationAllowsHoldToTalk: diagnosticsBool(fields["selectedConversationAllowsHoldToTalk"]) ?? false,
        selectedConversationAutoJoinArmed: diagnosticsBool(fields["selectedConversationAutoJoinArmed"]) ?? false,
        isJoined: diagnosticsBool(fields["isJoined"]) ?? false,
        isTransmitting: diagnosticsBool(fields["isTransmitting"]) ?? false,
        activeChannelID: optionalDiagnosticsString(fields["activeChannelId"]),
        systemSession: fields["systemSession"] ?? "none",
        systemActiveContactID: optionalDiagnosticsString(fields["systemActiveContactID"]),
        systemChannelUUID: optionalDiagnosticsString(fields["systemChannelUUID"]),
        mediaState: fields["mediaState"] ?? "none",
        transmitPhase: fields["transmitPhase"] ?? "idle",
        transmitActiveContactID: optionalDiagnosticsString(fields["transmitActiveContactID"]),
        transmitPressActive: diagnosticsBool(fields["transmitPressActive"]) ?? false,
        transmitExplicitStopRequested: diagnosticsBool(fields["transmitExplicitStopRequested"]) ?? false,
        transmitSystemTransmitting: diagnosticsBool(fields["transmitSystemTransmitting"]) ?? false,
        incomingWakeActivationState: optionalDiagnosticsString(fields["incomingWakeActivationState"]),
        incomingWakeBufferedChunkCount: fields["incomingWakeBufferedChunkCount"].flatMap(Int.init),
        remoteReceiveActive: diagnosticsBool(fields["remoteReceiveActive"]) ?? false,
        remoteTransmitStopObserved: diagnosticsBool(fields["remoteTransmitStopObserved"]) ?? false,
        remoteTransmitStopProjectionGraceActive:
            diagnosticsBool(fields["remoteTransmitStopProjectionGraceActive"]) ?? false,
        remoteReceiveActivityState: optionalDiagnosticsString(fields["remoteReceiveActivityState"]),
        receiverAudioReadinessState: optionalDiagnosticsString(fields["receiverAudioReadinessState"]),
        pendingAction: fields["pendingAction"] ?? "none",
        localJoinAttempt: optionalDiagnosticsString(fields["localJoinAttempt"]),
        localJoinAttemptIssuedCount: fields["localJoinAttemptIssuedCount"].flatMap(Int.init) ?? 0,
        reconciliationAction: fields["selectedConversationReconciliationAction"] ?? "none",
        hadConnectedDevicePTTContinuity: diagnosticsBool(fields["hadConnectedDevicePTTContinuity"]) ?? false,
        controlPlaneReconnectGraceActive: diagnosticsBool(fields["controlPlaneReconnectGraceActive"]) ?? false,
        backendSignalingJoinRecoveryActive: diagnosticsBool(fields["backendSignalingJoinRecoveryActive"]) ?? false,
        backendJoinSettling: diagnosticsBool(fields["backendJoinSettling"]) ?? false,
        backendChannelStatus: optionalDiagnosticsString(fields["backendChannelStatus"]),
        backendReadiness: optionalDiagnosticsString(fields["backendReadiness"]),
        backendSelfJoined: diagnosticsBool(fields["backendSelfJoined"]),
        backendPeerJoined: diagnosticsBool(fields["backendPeerJoined"]),
        backendPeerDeviceConnected: diagnosticsBool(fields["backendPeerDeviceConnected"]),
        backendActiveTransmitterUserId: optionalDiagnosticsString(fields["backendActiveTransmitterUserId"]),
        backendActiveTransmitId: optionalDiagnosticsString(fields["backendActiveTransmitId"]),
        backendActiveTransmitExpiresAt: optionalDiagnosticsString(fields["backendActiveTransmitExpiresAt"]),
        backendServerTimestamp: optionalDiagnosticsString(fields["backendServerTimestamp"]),
        backendCanTransmit: diagnosticsBool(fields["backendCanTransmit"]),
        remoteAudioReadiness: optionalDiagnosticsString(fields["remoteAudioReadiness"]),
        remoteWakeCapabilityKind: optionalDiagnosticsString(fields["remoteWakeCapabilityKind"])
    )
}

func optionalDiagnosticsString(_ value: String?) -> String? {
    guard let value, value != "none" else { return nil }
    return value
}

func diagnosticsBool(_ value: String?) -> Bool? {
    switch value {
    case "true":
        return true
    case "false":
        return false
    default:
        return nil
    }
}

func makeContactSummary(
    channelId: String?,
    handle: String = "@avery",
    displayName: String = "Avery",
    isOnline: Bool = true,
    hasIncomingBeep: Bool = false,
    hasOutgoingBeep: Bool = false,
    requestCount: Int = 0,
    isActiveConversation: Bool = false,
    badgeStatus: String = "online",
    membershipKind: String? = nil,
    peerDeviceConnected: Bool? = nil
) -> TurboContactSummaryResponse {
    TurboContactSummaryResponse(
        userId: "user-peer",
        handle: handle,
        displayName: displayName,
        channelId: channelId,
        isOnline: isOnline,
        hasIncomingBeep: hasIncomingBeep,
        hasOutgoingBeep: hasOutgoingBeep,
        requestCount: requestCount,
        isActiveConversation: isActiveConversation,
        badgeStatus: badgeStatus,
        membershipPayload: membershipKind.map {
            TurboChannelMembershipPayload(kind: $0, peerDeviceConnected: peerDeviceConnected)
        }
    )
}

func makeBeep(
    direction: String,
    beepId: String = UUID().uuidString,
    fromHandle: String = "@self",
    toHandle: String = "@avery",
    status: String = "pending",
    requestCount: Int = 1,
    createdAt: String = "2026-04-08T00:00:00Z",
    updatedAt: String? = nil,
    subject: String? = nil
) -> TurboBeepResponse {
    TurboBeepResponse(
        beepId: beepId,
        fromUserId: "user-self",
        fromHandle: fromHandle,
        toUserId: "user-peer",
        toHandle: toHandle,
        channelId: "channel-1",
        status: status,
        direction: direction,
        requestCount: requestCount,
        createdAt: createdAt,
        updatedAt: updatedAt,
        subject: subject,
        targetAvailability: nil,
        shouldAutoJoinFriend: nil,
        accepted: nil,
        pendingJoin: nil
    )
}

func makeStartCallIntent(handle: String, identifier: String) -> INStartCallIntent {
    let personHandle = INPersonHandle(value: handle, type: .unknown)
    let caller = INPerson(
        personHandle: personHandle,
        nameComponents: nil,
        displayName: handle,
        image: nil,
        contactIdentifier: nil,
        customIdentifier: nil
    )
    let callRecord = INCallRecord(
        identifier: identifier,
        dateCreated: Date(),
        caller: caller,
        callRecordType: .ringing,
        callCapability: .audioCall,
        callDuration: nil,
        unseen: true
    )
    return INStartCallIntent(
        callRecordFilter: nil,
        callRecordToCallBack: callRecord,
        audioRoute: .unknown,
        destinationType: .normal,
        contacts: [caller],
        callCapability: .audioCall
    )
}

func makeUnreachableBackendConfig() -> TurboBackendConfig {
    TurboBackendConfig(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        devUserHandle: "@self",
        deviceID: "test-device"
    )
}

func installSuccessfulBeginTransmitOverride(
    targetUserID: String = "peer-user",
    targetDeviceID: String = "peer-device",
    transmitID: String = "transmit-1"
) {
    let leaseFormatter = ISO8601DateFormatter()
    let leaseStartedAt = leaseFormatter.string(from: Date())
    let leaseExpiresAt = leaseFormatter.string(from: Date().addingTimeInterval(30))
    TurboBackendCriticalHTTPClient.beginTransmitOverride = { channelId, _ in
        TurboBeginTransmitResponse(
            channelId: channelId,
            status: "transmitting",
            transmitId: transmitID,
            startedAt: leaseStartedAt,
            expiresAt: leaseExpiresAt,
            targetUserId: targetUserID,
            targetDeviceId: targetDeviceID
        )
    }
}

func makeJoinResponseData(status: String) -> Data {
    Data(
        """
        {
          "channelId": "channel-1",
          "userId": "user-self",
          "deviceId": "test-device",
          "status": "\(status)"
        }
        """.utf8
    )
}

func makeLeaveResponseData(status: String) -> Data {
    Data(
        """
        {
          "channelId": "channel-1",
          "deviceId": "test-device",
          "status": "\(status)"
        }
        """.utf8
    )
}

func makePresenceHeartbeatResponseData(status: String) -> Data {
    Data(
        """
        {
          "deviceId": "test-device",
          "userId": "user-self",
          "status": "\(status)"
        }
        """.utf8
    )
}
