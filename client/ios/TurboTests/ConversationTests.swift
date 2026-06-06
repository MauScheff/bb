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
struct ConversationTests {
    @Test func shakeReportSensitivityRequiresDeliberateDuration() {
        let policy = ShakeReportSensitivityPolicy(minimumShakeDuration: 0.55)
        let startedAt = Date(timeIntervalSinceReferenceDate: 10)

        #expect(
            !policy.acceptsShake(
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(0.30)
            )
        )
        #expect(
            policy.acceptsShake(
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(0.55)
            )
        )
    }

    @Test func shakeReportSensitivityRejectsEndedShakeWithoutStart() {
        let policy = ShakeReportSensitivityPolicy(minimumShakeDuration: 0.55)

        #expect(
            !policy.acceptsShake(
                startedAt: nil,
                endedAt: Date(timeIntervalSinceReferenceDate: 10)
            )
        )
    }

    @Test func suggestedProfileNameUsesTwoWordsWithoutDigits() {
        for _ in 0..<32 {
            let candidate = TurboSuggestedProfileName.generate()
            let parts = candidate.split(separator: " ")
            #expect(parts.count == 2)
            #expect(candidate.contains(where: \.isNumber) == false)
        }
    }

    @Test func identityProfileStoreNormalizesWhitespace() {
        let normalized = TurboIdentityProfileStore.normalizedProfileName("  Sunny Otter  ")
        #expect(normalized == "Sunny Otter")
    }

    @Test func handleSuggestionUsesOnlyLowercaseLettersAndNumbers() {
        let suggested = TurboHandle.suggestedEditableBody(from: "Lively Sparrow")
        #expect(suggested == "livelysparrow")
        #expect(TurboHandle.isValidEditableBody(suggested))
    }

    @Test func contactDisplayNamePrefersLocalOverride() {
        var contact = Contact(
            id: UUID(),
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            localName: "Studio Blake"
        )

        #expect(contact.name == "Studio Blake")
        #expect(contact.hasLocalNameOverride)

        contact.localName = nil

        #expect(contact.name == "Blake")
        #expect(contact.hasLocalNameOverride == false)
    }

    @Test func contactAliasStoreScopesAliasesByOwner() {
        let contactID = UUID()
        let firstOwner = "owner-a-\(UUID().uuidString)"
        let secondOwner = "owner-b-\(UUID().uuidString)"
        let suiteName = "TurboTests.contact-aliases.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let stored = TurboContactAliasStore.storeLocalName(
            "  Harbor Blake  ",
            for: contactID,
            ownerKey: firstOwner,
            defaults: defaults
        )
        #expect(stored == "Harbor Blake")
        #expect(TurboContactAliasStore.localName(for: contactID, ownerKey: firstOwner, defaults: defaults) == "Harbor Blake")
        #expect(TurboContactAliasStore.localName(for: contactID, ownerKey: secondOwner, defaults: defaults) == nil)

        let cleared = TurboContactAliasStore.storeLocalName(
            nil,
            for: contactID,
            ownerKey: firstOwner,
            defaults: defaults
        )
        #expect(cleared == nil)
        #expect(TurboContactAliasStore.localName(for: contactID, ownerKey: firstOwner, defaults: defaults) == nil)
    }

    @Test func contactAliasStoreIgnoresStaleNonDictionaryValue() {
        let contactID = UUID()
        let owner = "owner-\(UUID().uuidString)"
        let suiteName = "TurboTests.contact-aliases-stale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(Date(timeIntervalSinceReferenceDate: 0), forKey: "TurboContactAliasesByOwner")

        #expect(TurboContactAliasStore.localName(for: contactID, ownerKey: owner, defaults: defaults) == nil)

        let stored = TurboContactAliasStore.storeLocalName(
            "  Harbor Blake  ",
            for: contactID,
            ownerKey: owner,
            defaults: defaults
        )

        #expect(stored == "Harbor Blake")
        #expect(TurboContactAliasStore.localName(for: contactID, ownerKey: owner, defaults: defaults) == "Harbor Blake")
    }

    @MainActor
    @Test func selectedContactPublishesSelectedFriendPrewarmHint() async throws {
        let contactID = UUID()
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
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-peer"
        )
        viewModel.contacts = [contact]

        viewModel.selectContact(contact)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let envelope = try #require(client.sentSignalsForTesting().first)
        let payload = try envelope.decodeSelectedFriendPrewarmPayload()
        #expect(envelope.type == .selectedFriendPrewarm)
        #expect(envelope.channelId == "channel-1")
        #expect(envelope.fromUserId == "user-self")
        #expect(envelope.fromDeviceId == "self-device")
        #expect(envelope.toUserId == "user-peer")
        #expect(envelope.toDeviceId == "")
        #expect(payload.reason == "selected-contact")
        #expect(payload.toDeviceId == "")
        #expect(viewModel.diagnosticsTranscript.contains("Selected friend prewarm hint sent"))
        #expect(viewModel.diagnosticsTranscript.contains("Selected contact prewarm pipeline started"))
        #expect(viewModel.diagnosticsTranscript.contains("stage=friend-prewarm-hint"))
        #expect(viewModel.diagnosticsTranscript.contains("Selected contact prewarm pipeline completed"))
    }

    @MainActor
    @Test func detailFocusSelectionRunsSelectedContactPrewarmPipeline() async throws {
        let contactID = UUID()
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
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-peer"
        )
        viewModel.contacts = [contact]

        viewModel.selectContact(contact, reason: "contact-list-focused-detail")
        try? await Task.sleep(nanoseconds: 100_000_000)

        let envelope = try #require(client.sentSignalsForTesting().first)
        let payload = try envelope.decodeSelectedFriendPrewarmPayload()
        #expect(envelope.type == .selectedFriendPrewarm)
        #expect(payload.reason == "contact-list-focused-detail")
        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.diagnosticsTranscript.contains("reason=contact-list-focused-detail"))
        #expect(viewModel.diagnosticsTranscript.contains("Selected contact prewarm pipeline completed"))
    }

    @MainActor
    @Test func selectedFriendPrewarmHintRunsSelectedContactPipelineWithoutEchoingHint() async throws {
        let contactID = UUID()
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
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-peer"
            )
        ]
        viewModel.selectedContactId = contactID
        let payload = TurboSelectedFriendPrewarmPayload(
            requestId: "selected-prewarm-1",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: "self-device",
            reason: "selected-contact"
        )
        let envelope = try TurboSignalEnvelope.selectedFriendPrewarm(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: "self-device",
            payload: payload
        )

        await viewModel.ingestBackendWebSocketSignal(envelope)
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sentSignalsForTesting().isEmpty)
        #expect(viewModel.diagnosticsTranscript.contains("Selected friend prewarm hint received"))
        #expect(viewModel.diagnosticsTranscript.contains("reason=friend-hint-selected-contact"))
        #expect(viewModel.diagnosticsTranscript.contains("initialBlockReason=friend-hint-loop-suppressed"))
        #expect(viewModel.diagnosticsTranscript.contains("Selected contact prewarm pipeline completed"))
    }

    @MainActor
    @Test func joinAcceptedControlSignalStartsSelectedOutgoingBeepJoin() async throws {
        let contactID = UUID()
        let channelUUID = UUID()
        let pttClient = RecordingPTTSystemClient()
        let backendClient = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        backendClient.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        viewModel.applyAuthenticatedBackendSession(
            client: backendClient,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .outgoingBeepSeeded(
                contactID: contactID,
                beep: makeBeep(direction: "outgoing", beepId: "beep-accepted"),
                now: Date()
            )
        )
        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        let payload = TurboDirectQuicUpgradeRequestPayload(
            requestId: "beep-accepted",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: "self-device",
            reason: TurboJoinAcceptedControlSignal.reason,
            roleIntent: .symmetric
        )
        let envelope = try TurboSignalEnvelope.directQuicUpgradeRequest(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: "self-device",
            payload: payload
        )

        viewModel.handleIncomingSignal(envelope)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.joinRequests == [channelUUID])
        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == contactID)
        #expect(viewModel.backendRuntime.isBackendJoinSettling(for: contactID))
        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID
                    && request.intent == .joinAcceptedOutgoingBeep
            }
        )
        #expect(viewModel.diagnosticsTranscript.contains("Join accepted control signal received"))
    }

    @MainActor
    @Test func joinAcceptedControlSignalUsesRecentOutgoingBeepEvidenceAfterIdleProjectionRace() async throws {
        let contactID = UUID()
        let channelUUID = UUID()
        let pttClient = RecordingPTTSystemClient()
        let backendClient = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        backendClient.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        viewModel.applyAuthenticatedBackendSession(
            client: backendClient,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.recordRecentOutgoingBeepEvidenceIfNeeded(
            contactID: contactID,
            relationship: .outgoingBeep(requestCount: 1)
        )

        let payload = TurboDirectQuicUpgradeRequestPayload(
            requestId: "beep-accepted",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: "self-device",
            reason: TurboJoinAcceptedControlSignal.reason,
            roleIntent: .symmetric
        )
        let envelope = try TurboSignalEnvelope.directQuicUpgradeRequest(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: "self-device",
            payload: payload
        )

        viewModel.handleIncomingSignal(envelope)

        #expect(pttClient.joinRequests == [channelUUID])
        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == contactID)
        #expect(viewModel.backendRuntime.isBackendJoinSettling(for: contactID))
        #expect(viewModel.recentOutgoingBeepEvidenceByContactID[contactID] == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Join accepted control signal received"))
    }

    @MainActor
    @Test func joinAcceptedControlSignalSelectsContactAfterRelaunchProjectionReset() async throws {
        let contactID = UUID()
        let channelUUID = UUID()
        let pttClient = RecordingPTTSystemClient()
        let backendClient = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        backendClient.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        viewModel.applyAuthenticatedBackendSession(
            client: backendClient,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-peer"
            )
        ]
        viewModel.selectedContactId = nil
        viewModel.backendSyncCoordinator.send(
            .outgoingBeepSeeded(
                contactID: contactID,
                beep: makeBeep(direction: "outgoing", beepId: "beep-accepted"),
                now: Date()
            )
        )
        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        let payload = TurboDirectQuicUpgradeRequestPayload(
            requestId: "beep-accepted",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: "self-device",
            reason: TurboJoinAcceptedControlSignal.reason,
            roleIntent: .symmetric
        )
        let envelope = try TurboSignalEnvelope.directQuicUpgradeRequest(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: "self-device",
            payload: payload
        )

        viewModel.handleIncomingSignal(envelope)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.selectedContactId == contactID)
        #expect(pttClient.joinRequests == [channelUUID])
        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == contactID)
        #expect(viewModel.backendRuntime.isBackendJoinSettling(for: contactID))
        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID
                    && request.intent == .joinAcceptedOutgoingBeep
            }
        )
        #expect(viewModel.diagnosticsTranscript.contains("Selected contact for accepted outgoing Beep control signal"))
        #expect(viewModel.diagnosticsTranscript.contains("Join accepted control signal received"))
        #expect(!viewModel.diagnosticsTranscript.contains("Ignored join accepted control signal for non-selected contact"))
    }

    @MainActor
    @Test func joinAcceptedControlSignalDoesNotReopenCallWhileLeaveIsActive() async throws {
        let contactID = UUID()
        let channelUUID = UUID()
        let pttClient = RecordingPTTSystemClient()
        let backendClient = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        backendClient.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        viewModel.applyAuthenticatedBackendSession(
            client: backendClient,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .outgoingBeepSeeded(
                contactID: contactID,
                beep: makeBeep(direction: "outgoing", beepId: "beep-accepted"),
                now: Date()
            )
        )

        let payload = TurboDirectQuicUpgradeRequestPayload(
            requestId: "beep-accepted",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: "self-device",
            reason: TurboJoinAcceptedControlSignal.reason,
            roleIntent: .symmetric
        )
        let envelope = try TurboSignalEnvelope.directQuicUpgradeRequest(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: "self-device",
            payload: payload
        )

        viewModel.handleIncomingSignal(envelope)

        #expect(pttClient.joinRequests.isEmpty)
        #expect(viewModel.conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID))
        #expect(viewModel.diagnosticsTranscript.contains("Ignored join accepted control signal while leave is active"))
    }

    @Test func explicitLeaveBlocksAutoRejoin() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID, channelUUID: UUID())
        coordinator.markExplicitLeave(contactID: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.localJoinAttempt == nil)
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func staleJoinedChannelRefreshDuringLeaveIsTreatedAsTombstoned() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let existing = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let staleIncoming = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )

        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)

        #expect(
            viewModel.effectiveChannelStatePreservingConversationMembership(
                contactID: contactID,
                existing: existing,
                incoming: staleIncoming
            ) == staleIncoming
        )
        #expect(
            viewModel.shouldIgnoreStaleJoinedChannelRefreshDuringLeave(
                contactID: contactID,
                effectiveChannelState: staleIncoming,
                localDevicePTTEvidenceCleared: true
            )
        )
    }

    @Test func backendJoinedRefreshDoesNotReopenEngineConversationDuringLeave() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.seedEngineJoinedConversationForTesting(
            contactID: contactID,
            backendChannelID: "channel-1"
        )

        #expect(viewModel.isJoined)

        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)
        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "stale-channel-refresh")

        #expect(!viewModel.isJoined)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Ignored backend joined Conversation while leave is in flight"
            }
        )
    }

    @Test func backendJoinedRefreshDoesNotReopenEngineConversationAfterRecentSystemLeave() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(
            contactID: contactID,
            backendChannelID: "channel-1"
        )
        viewModel.markStaleSystemRejoinSuppression(
            channelUUID: channelUUID,
            contactID: contactID,
            reason: "recent-system-leave"
        )

        #expect(viewModel.isJoined)

        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "stale-channel-refresh")

        #expect(!viewModel.isJoined)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Ignored backend joined Conversation after recent system leave"
            }
        )
    }

    @Test func queueJoinDoesNotOverrideExplicitLeave() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.queueJoin(contactID: contactID)

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: contactID)))
    }

    @Test func globalExplicitLeaveBlocksAutoRejoin() {
        var coordinator = ConversationActionCoordinatorState()

        coordinator.markExplicitLeave(contactID: nil)

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: nil)))
        #expect(coordinator.autoRejoinContactID(afterLeaving: nil) == nil)
    }

    @Test func selectingContactDoesNotClearGlobalExplicitLeave() {
        var coordinator = ConversationActionCoordinatorState()
        let selectedContactID = UUID()

        coordinator.markExplicitLeave(contactID: nil)
        coordinator.select(contactID: selectedContactID)

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: nil)))
    }

    @Test func reconciledTeardownBlocksAutoRejoinUntilLeaveCompletes() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID, channelUUID: UUID())
        coordinator.markReconciledTeardown(contactID: contactID)

        #expect(coordinator.pendingAction == .leave(.reconciledTeardown(contactID: contactID)))
        #expect(coordinator.localJoinAttempt == nil)
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func clearLeaveActionResetsMatchingPendingTeardown() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.markReconciledTeardown(contactID: contactID)
        coordinator.clearLeaveAction(for: contactID)

        #expect(coordinator == ConversationActionCoordinatorState())
    }

    @Test func clearExplicitLeaveResetsMatchingPendingLeave() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.clearExplicitLeave(for: contactID)

        #expect(coordinator == ConversationActionCoordinatorState())
    }

    @Test func clearExplicitLeaveKeepsOtherPendingLeave() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.clearExplicitLeave(for: UUID())

        #expect(coordinator != ConversationActionCoordinatorState())
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func successfulJoinClearsPendingJoin() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID, channelUUID: UUID())
        coordinator.clearAfterSuccessfulJoin(for: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.localJoinAttempt == nil)
    }

    @Test func clearingPendingJoinWithoutSessionStopsWaitingTransition() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID, channelUUID: UUID())
        coordinator.clearPendingJoin(for: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.localJoinAttempt == nil)
    }

    @Test func queuedConnectSurvivesUntilRejoinAfterLeave() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueConnect(contactID: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.autoRejoinContactID(afterLeaving: nil) == contactID)
    }

    @Test func selectingContactDoesNotQueueJoin() {
        var coordinator = ConversationActionCoordinatorState()
        let selectedContactID = UUID()
        let pendingContactID = UUID()

        coordinator.queueJoin(contactID: pendingContactID, channelUUID: UUID())
        coordinator.select(contactID: selectedContactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.localJoinAttempt == nil)
    }

    @Test func selectedConversationStateUsesDisconnectingStatusWhileExplicitLeaveIsInFlight() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: false,
                systemSessionState: .none,
                pendingAction: .leave(.explicit(contactID: contactID)),
                localJoinFailure: nil,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Disconnecting...")
        #expect(state.canTransmitNow == false)
    }

    @Test func retainedContactsOnlyKeepAuthoritativeIDs() {
        let avery = Contact(
            id: Contact.stableID(for: "@avery"),
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-avery",
            remoteUserId: "user-avery"
        )
        let blake = Contact(
            id: Contact.stableID(for: "@blake"),
            name: "Blake",
            handle: "@blake",
            isOnline: false,
            channelId: UUID(),
            backendChannelId: "channel-blake",
            remoteUserId: "user-blake"
        )
        let tatum = Contact(
            id: Contact.stableID(for: "@tatum"),
            name: "Tatum",
            handle: "@tatum",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-tatum",
            remoteUserId: "user-tatum"
        )

        let contacts = ContactDirectory.retainedContacts(
            existingContacts: [tatum, blake, avery],
            authoritativeContactIDs: [avery.id, blake.id]
        )

        #expect(contacts.map(\.handle) == ["@avery", "@blake"])
    }

    @Test func alignedSessionDoesNotTearDownOnTransientPeerDeparture() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func alignedWaitingForPeerWithPendingRequestDoesNotTearDown() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func explicitLeaveStillTearsDownWhenSystemSessionClears() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .leave(.explicit(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func recoverableSystemMismatchWithConnectedDevicePTTContinuityDoesNotTearDown() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            hadConnectedDevicePTTContinuity: true,
            channel: nil
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.devicePTTContinuity == .transitioning)
        #expect(projection.reconciliationAction == .none)
        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(projection.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func pendingJoinSystemMismatchDoesNotTearDownDuringInitialJoin() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.devicePTTContinuity == .transitioning)
        #expect(projection.reconciliationAction == .none)
        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(projection.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func requestCoveredSystemMismatchDoesNotTearDownJoinedHandshake() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .incomingBeep,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .incomingBeep,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: true
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .incomingBeep(requestCount: 1))

        #expect(projection.devicePTTContinuity == .transitioning)
        #expect(projection.reconciliationAction == .none)
        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(projection.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func unattributedJoinedSystemMismatchDoesNotTearDownFreshJoin() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.devicePTTContinuity == .transitioning)
        #expect(projection.reconciliationAction == .none)
        #expect(projection.selectedConversationState.phase == .waitingForPeer)
    }

    @Test func terminalSystemMismatchWithoutConnectedDevicePTTContinuityStillTearsDown() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.devicePTTContinuity == .systemMismatch)
        #expect(
            projection.reconciliationAction
                == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func suggestedDevHandlesIncludeCorePeers() {
        #expect(ContactDirectory.suggestedDevHandles.contains("@avery"))
        #expect(ContactDirectory.suggestedDevHandles.contains("@blake"))
        #expect(ContactDirectory.suggestedDevHandles.contains("@turbo-ios"))
    }

    @Test func waitingForPeerPrimaryActionIsDisabled() {
        let action = ConversationStateMachine.primaryAction(
            conversationState: .waitingForPeer,
            isSelectedChannelJoined: true,
            canTransmitNow: false,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        switch action.kind {
        case .connect:
            break
        case .holdToTalk:
            Issue.record("Expected connect primary action while waiting for peer")
        }
        #expect(action.label == "Waiting for Peer")
        #expect(action.isEnabled == false)
        switch action.style {
        case .muted:
            break
        case .accent, .active:
            Issue.record("Expected muted styling while waiting for peer")
        }
    }

    @Test func idlePrimaryActionUsesBeepLabelWhenTapWillSendBeep() {
        let action = ConversationStateMachine.primaryAction(
            conversationState: .idle,
            isSelectedChannelJoined: false,
            canTransmitNow: false,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        switch action.kind {
        case .connect:
            break
        case .holdToTalk:
            Issue.record("Expected connect-style primary action while idle")
        }
        #expect(action.label == "Send Beep")
        #expect(action.isEnabled)
        switch action.style {
        case .accent:
            break
        case .muted, .active:
            Issue.record("Expected accent styling for idle Beep action")
        }
    }

    @Test func selectedConversationStateKeepsOutgoingRequestOutOfWaitingWithoutSessionTransition() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .outgoingBeep(requestCount: 2)
        )

        #expect(state.phase == .outgoingBeep)
        #expect(state.conversationState == .outgoingBeep)
        #expect(state.statusMessage == "Beep sent to Blake")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedConversationIdleStateKeepsOnlineStatusForReachablePeer() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: false,
            contactPresence: .reachable,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .idle)
        #expect(state.statusMessage == "Blake is online")
    }

    @Test func selectedConversationIdleDisplayStatusUsesOnlineForReachablePeer() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: false,
            contactPresence: .reachable,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.displayStatus == .online)
    }

    @Test func selectedConversationStateUsesWaitingDuringPendingJoin() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Connecting...")
    }

    @Test func selectedConversationStateKeepsRequestSubmissionOutOfWaiting() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .outgoingBeep,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .outgoingBeep(requestCount: 1)
        )

        #expect(state.phase == .outgoingBeep)
        #expect(state.conversationState == .outgoingBeep)
        #expect(state.statusMessage == "Beep sent to Avery")
    }

    @Test func acceptedIncomingBeepRequestSubmissionKeepsBeepProjectionOutOfWaiting() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .incomingBeep,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
            pendingConnectAcceptedIncomingBeep: true,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .incomingBeep,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: true
                )
            )
        )

        let projection = ConversationStateMachine.projection(
            for: context,
            relationship: .incomingBeep(requestCount: 1)
        )

        #expect(projection.selectedConversationState.phase == .incomingBeep)
        #expect(projection.selectedConversationState.conversationState == .incomingBeep)
        #expect(projection.selectedConversationState.statusMessage == "Avery wants to talk")
        #expect(!projection.selectedConversationState.canTransmitNow)
        #expect(!projection.selectedConversationState.allowsHoldToTalk)
        #expect(projection.reconciliationAction == .none)
    }

    @Test func backendJoinSettlingSuppressesStaleBeepProjectionTeardownAfterAcceptedJoin() {
        let contactID = UUID()
        let channelID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            relationship: .incomingBeep(requestCount: 1),
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelID),
            pendingAction: .none,
            localJoinFailure: nil,
            backendConvergence: BackendConversationConvergenceState(
                joinSettling: true,
                signalingJoinRecoveryActive: false,
                controlPlaneReconnectGraceActive: false
            ),
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: true
                )
            )
        )

        let projection = ConversationStateMachine.projection(
            for: context,
            relationship: .incomingBeep(requestCount: 1)
        )

        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(projection.reconciliationAction == .none)
    }

    @Test func pendingOutgoingBeepDominatesPeerReadyBackendProjection() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .outgoingBeep,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .outgoingBeep,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasOutgoingBeep: true
                )
            )
        )

        let projection = ConversationStateMachine.projection(
            for: context,
            relationship: .outgoingBeep(requestCount: 1)
        )

        #expect(projection.selectedConversationState.phase == .outgoingBeep)
        #expect(projection.selectedConversationState.conversationState == .outgoingBeep)
        #expect(projection.selectedConversationState.statusMessage == "Beep sent to Avery")
        #expect(!projection.selectedConversationState.canTransmitNow)
        #expect(!projection.selectedConversationState.allowsHoldToTalk)
        #expect(projection.reconciliationAction == .none)
    }

    @Test func pendingIncomingBeepDominatesStaleJoinedLocalSession() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .incomingBeep,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .incomingBeep,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: true
                )
            )
        )

        let projection = ConversationStateMachine.projection(
            for: context,
            relationship: .incomingBeep(requestCount: 1)
        )

        #expect(projection.selectedConversationState.phase == .incomingBeep)
        #expect(projection.selectedConversationState.conversationState == .incomingBeep)
        #expect(projection.selectedConversationState.statusMessage == "Avery wants to talk")
        #expect(!projection.selectedConversationState.canTransmitNow)
        #expect(!projection.selectedConversationState.allowsHoldToTalk)
        #expect(projection.reconciliationAction == .teardownDevicePTTSession(contactID: contactID))
    }

    @Test func selectedConversationStatePreservesConnectingWhileAcceptedIncomingBeepIsStillJoining() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
            pendingConnectAcceptedIncomingBeep: true,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Connecting...")
        #expect(!state.canTransmitNow)
    }

    @Test func selectedConversationStateWaitsWhenPeerIsDisconnectedWithoutWakeCapability() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteWakeCapability: .unavailable
                )
            )
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Avery to reconnect")
        #expect(state.canTransmitNow == false)
    }

    @Test func contactStableIDUsesRemoteUserIdAcrossPublicIdChanges() {
        let original = Contact.stableID(remoteUserId: "user-blake", fallbackHandle: "@blake")
        let renamed = Contact.stableID(remoteUserId: "user-blake", fallbackHandle: "maurice")
        let fallbackOnly = Contact.stableID(remoteUserId: nil, fallbackHandle: "@blake")

        #expect(original == renamed)
        #expect(original != fallbackOnly)
    }

    @Test func ensureContactMatchesExistingRemoteUserWhenPublicIdChanges() {
        let existingContactID = Contact.stableID(remoteUserId: "user-blake", fallbackHandle: "@blake")
        let existing = [
            Contact(
                id: existingContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            )
        ]

        let result = ContactDirectory.ensureContact(
            handle: "maurice",
            remoteUserId: "user-blake",
            channelId: "",
            displayName: "Maurice",
            existingContacts: existing
        )

        let refreshed = try! #require(result.contacts.first)
        #expect(result.contacts.count == 1)
        #expect(result.contactID == existingContactID)
        #expect(refreshed.id == existingContactID)
        #expect(refreshed.handle == "@maurice")
        #expect(refreshed.name == "Maurice")
        #expect(refreshed.remoteUserId == "user-blake")
    }

    @Test func ensureContactPreservesExistingProfileNameWhenRefreshOmitsDisplayName() {
        let existingContactID = Contact.stableID(remoteUserId: "user-blake", fallbackHandle: "@blake")
        let existing = [
            Contact(
                id: existingContactID,
                profileName: "Lively Sparrow",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            )
        ]

        let result = ContactDirectory.ensureContact(
            handle: "@blake",
            remoteUserId: "user-blake",
            channelId: "",
            displayName: nil,
            existingContacts: existing
        )

        let refreshed = try! #require(result.contacts.first)
        #expect(result.contacts.count == 1)
        #expect(refreshed.id == existingContactID)
        #expect(refreshed.profileName == "Lively Sparrow")
        #expect(refreshed.name == "Lively Sparrow")
    }

    @Test func selectedConversationReducerKeepsOutgoingRequestRequestedUntilRealTransitionStarts() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let events: [SelectedConversationEvent] = [
            .selectedContactChanged(selection),
            .relationshipUpdated(.outgoingBeep(requestCount: 2)),
            .baseStateUpdated(.outgoingBeep),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let state = reduceSelectedConversationState(events)

        #expect(state.selectedConversationState.phase == .outgoingBeep)
        #expect(state.selectedConversationState.conversationState == .outgoingBeep)
        #expect(state.selectedConversationState.statusMessage == "Beep sent to Blake")
    }

    @Test func selectedConversationReducerClearsSenderAutoJoinWhenOutgoingBeepDisappears() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let requestedState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.outgoingBeep(requestCount: 1)),
            .baseStateUpdated(.outgoingBeep),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        #expect(requestedState.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(requestedState.selectedConversationState.phase == .outgoingBeep)

        let declinedState = [
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil)
        ].reduce(requestedState) { state, event in
            SelectedConversationReducer.reduce(state: state, event: event).state
        }

        #expect(declinedState.senderAutoJoinOnBeepAcceptanceArmed == false)
        #expect(declinedState.senderAutoJoinOnBeepAcceptanceDispatchInFlight == false)
        #expect(declinedState.selectedConversationState.phase == .idle)
        #expect(declinedState.selectedConversationState.statusMessage == "Blake is online")
    }

    @Test func selectedConversationReducerDoesNotRearmSenderAutoJoinAfterDeclineTimeout() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let requestedState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.outgoingBeep(requestCount: 1)),
            .baseStateUpdated(.outgoingBeep),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .outgoingBeep,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false,
                        hasOutgoingBeep: true
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        #expect(requestedState.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(requestedState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep)

        let acceptedGap = [
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .idle,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            )
        ].reduce(requestedState) { state, event in
            SelectedConversationReducer.reduce(state: state, event: event).state
        }

        #expect(acceptedGap.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(acceptedGap.interruptedConnectionAttemptContactID == nil)
        #expect(acceptedGap.selectedConversationState.phase == .idle)
        #expect(acceptedGap.selectedConversationState.statusMessage == "Blake is online")

        let timedOut = SelectedConversationReducer.reduce(
            state: acceptedGap,
            event: .connectionAttemptTimedOut(contactID: contactID)
        ).state

        let staleOutgoingRefresh = SelectedConversationReducer.reduce(
            state: timedOut,
            event: .relationshipUpdated(.outgoingBeep(requestCount: 1))
        ).state
        let declinedRefresh = [
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .idle,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            )
        ].reduce(staleOutgoingRefresh) { state, event in
            SelectedConversationReducer.reduce(state: state, event: event).state
        }

        #expect(declinedRefresh.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(declinedRefresh.senderAutoJoinOnBeepAcceptanceDispatchInFlight == false)
        #expect(declinedRefresh.selectedConversationState.phase == .idle)
        #expect(declinedRefresh.selectedConversationState.statusMessage == "Blake is online")
    }

    @Test func selectedConversationReducerUsesWaitingForPendingJoin() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let events: [SelectedConversationEvent] = [
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .connect(.joiningLocal(contactID: contactID)),
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let state = reduceSelectedConversationState(events)

        #expect(state.selectedConversationState.phase == .waitingForPeer)
        #expect(state.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationReducerDoesNotDispatchDuplicateLocalRestoreWhileRetryIsInFlight() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )
        let readyChannel = ChannelReadinessSnapshot(
            channelState: makeChannelState(
                status: .ready,
                canTransmit: true,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            readiness: makeChannelReadiness(
                status: .ready,
                selfHasActiveDevice: true,
                peerHasActiveDevice: true,
                remoteAudioReadiness: .ready
            )
        )
        let initialState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(readyChannel),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let restoreTransition = SelectedConversationReducer.reduce(
            state: initialState,
            event: .reconcileRequested
        )
        #expect(restoreTransition.effects == [.restoreDevicePTTSession(contactID: contactID)])

        let stalePendingJoinState = SelectedConversationReducer.reduce(
            state: restoreTransition.state,
            event: .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .connect(.joiningLocal(contactID: contactID)),
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            )
        ).state

        let duplicateRestoreTransition = SelectedConversationReducer.reduce(
            state: stalePendingJoinState,
            event: .reconcileRequested
        )
        #expect(duplicateRestoreTransition.effects.isEmpty)
    }

    @Test func selectedConversationReducerPreservesConnectedContinuityAcrossSelectionRefreshes() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let readyState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: channelUUID),
                matchesSelectedContact: true
            ),
            .mediaStateUpdated(.connected)
        ])

        #expect(readyState.hadConnectedDevicePTTContinuity)

        let refreshedState = SelectedConversationReducer.reduce(
            state: readyState,
            event: .selectedContactChanged(
                SelectedConversationSelection(
                    contactID: contactID,
                    contactName: "Avery",
                    contactIsOnline: true
                )
            )
        ).state

        #expect(refreshedState.hadConnectedDevicePTTContinuity)
        #expect(refreshedState.selectedConversationState.phase == .ready)
        #expect(refreshedState.selectedConversationState.statusMessage == "Connected")
    }

    @Test func selectedConversationReducerKeepsSelfOnlyHandshakeWaitingBeforeAnyConnectedDevicePTTContinuityExists() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForPeer,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: channelUUID),
                matchesSelectedContact: true
            ),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.hadConnectedDevicePTTContinuity == false)
        #expect(state.selectedConversationState.phase == .waitingForPeer)
        #expect(state.selectedConversationState.statusMessage == "Connecting...")
        #expect(state.connectedControlPlaneProjection == .unavailable)
    }

    @Test func selectedConversationReducerRestoresSelfOnlyWakeCapableBackendRecoveryWithoutLocalPTTEvidence() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForPeer,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        #expect(state.selectedConversationState.phase == .waitingForPeer)
        #expect(state.selectedConversationState.statusMessage == "Connecting...")
        #expect(state.reconciliationAction == .restoreDevicePTTSession(contactID: contactID))

        let transition = SelectedConversationReducer.reduce(
            state: state,
            event: .reconcileRequested
        )

        #expect(transition.effects == [.restoreDevicePTTSession(contactID: contactID)])
    }

    @Test func selectedConversationReducerKeepsConnectedStatusWhileExplicitStopIsInFlight() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .transmitting, canTransmit: false),
                    readiness: makeChannelReadiness(
                        status: .selfTransmitting(activeTransmitterUserId: "self"),
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .localTransmitUpdated(.stopping),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.selectedConversationState.phase == .ready)
        #expect(state.selectedConversationState.detail == .ready)
        #expect(state.selectedConversationState.statusMessage == "Connected")
        #expect(state.selectedConversationState.canTransmitNow == false)
    }

    @Test func selectedConversationReducerJoinRequestEmitsConnectForJoinableSelection() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.outgoingBeep(requestCount: 1)),
            .baseStateUpdated(.outgoingBeep),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.requestConnection(contactID: contactID)])
    }

    @Test func selectedConversationReducerArmsSenderAutoJoinShortcutForOutgoingBeep() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.requestConnection(contactID: contactID)])
        #expect(transition.state.senderAutoJoinOnBeepAcceptanceArmed)
    }

    @Test func selectedConversationReducerDoesNotProjectConnectingBeforeOutgoingRequestIsVisible() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedConversationReducer.reduce(
            state: reduceSelectedConversationState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let transition = SelectedConversationReducer.reduce(
            state: armedState,
            event: .channelUpdated(nil)
        )

        #expect(transition.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(transition.state.selectedConversationState.phase == .idle)
        #expect(transition.state.selectedConversationState.statusMessage == "Blake is online")
    }

    @Test func selectedConversationReducerArmsSenderAutoJoinShortcutForOutstandingOutgoingBeep() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let transition = SelectedConversationReducer.reduce(
            state: .initial,
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: selection,
                    relationship: .outgoingBeep(requestCount: 1),
                    baseState: .outgoingBeep,
                    channel: nil,
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    senderAutoJoinOnBeepAcceptanceEnabled: true,
                    localTransmit: .idle,
                    remoteParticipantSignalIsTransmitting: false,
                    systemSessionState: .none,
                    systemSessionMatchesContact: false,
                    mediaState: .idle,
                    localRelayTransportReady: true,
                    directMediaPathActive: false,
                    incomingWakeActivationState: nil,
                    localJoinFailure: nil
                )
            )
        )

        #expect(transition.effects.isEmpty)
        #expect(transition.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(transition.state.selectedConversationState.phase == .outgoingBeep)
    }

    @Test func selectedConversationReducerDoesNotArmSenderAutoJoinShortcutWhenAcceptingIncomingBeep() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.incomingBeep(requestCount: 1)),
            .baseStateUpdated(.incomingBeep),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.requestConnection(contactID: contactID)])
        #expect(!transition.state.senderAutoJoinOnBeepAcceptanceArmed)
    }

    @Test func selectedConversationReducerDoesNotProjectConnectingWhileSenderAutoJoinAwaitingAcceptanceVisibility() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedConversationReducer.reduce(
            state: reduceSelectedConversationState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let transition = SelectedConversationReducer.reduce(
            state: armedState,
            event: .relationshipUpdated(.none)
        )

        #expect(transition.effects.isEmpty)
        #expect(transition.state.selectedConversationState.phase == .idle)
        #expect(transition.state.selectedConversationState.statusMessage == "Blake is online")
        #expect(!transition.state.selectedConversationState.canTransmitNow)
    }

    @Test func selectedConversationReducerClearsSenderAutoJoinShortcutAfterExplicitCancel() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedConversationReducer.reduce(
            state: reduceSelectedConversationState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let transition = SelectedConversationReducer.reduce(
            state: armedState,
            event: .senderAutoJoinCancelled(contactID: contactID)
        )

        #expect(!transition.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(!transition.state.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(transition.effects.isEmpty)
        #expect(transition.state.selectedConversationState.phase == .idle)
        #expect(transition.state.selectedConversationState.statusMessage == "Blake is online")
    }

    @Test func selectedConversationReducerKeepsConnectingAfterSenderAutoJoinEffectDispatchUntilLocalJoinReflects() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedConversationReducer.reduce(
            state: reduceSelectedConversationState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let readyTransition = SelectedConversationReducer.reduce(
            state: SelectedConversationReducer.reduce(
                state: armedState,
                event: .relationshipUpdated(.none)
            ).state,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(readyTransition.effects == [.joinReadyFriend(contactID: contactID)])
        #expect(readyTransition.state.selectedConversationState.phase == .waitingForPeer)
        #expect(readyTransition.state.selectedConversationState.statusMessage == "Connecting...")

        let bridgedTransition = SelectedConversationReducer.reduce(
            state: readyTransition.state,
            event: .baseStateUpdated(.idle)
        )

        #expect(bridgedTransition.effects.isEmpty)
        #expect(bridgedTransition.state.selectedConversationState.phase == .waitingForPeer)
        #expect(bridgedTransition.state.selectedConversationState.statusMessage == "Connecting...")
        #expect(!bridgedTransition.state.selectedConversationState.canTransmitNow)
    }

    @Test func selectedConversationReducerDisconnectRequestEmitsDisconnectForPendingJoin() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .connect(.joiningLocal(contactID: contactID)),
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .disconnectRequested)

        #expect(transition.effects == [.disconnect(contactID: contactID)])
    }

    @Test func selectedConversationReducerDisconnectRequestSkipsDuplicateDisconnectDuringExplicitLeave() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .leave(.explicit(contactID: contactID)),
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .disconnectRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedConversationReducerReconcileRequestEmitsRestoreEffectWhenContinuityExists() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        var seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])
        seededState.hadConnectedDevicePTTContinuity = true

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects == [.restoreDevicePTTSession(contactID: contactID)])
    }

    @Test func selectedConversationReducerReconcileRequestSkipsDuplicateTeardownDuringExplicitLeave() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .leave(.explicit(contactID: contactID)),
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedConversationReducerReconcileRequestSkipsDuplicateTeardownWhileTeardownIsInFlight() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .leave(.reconciledTeardown(contactID: contactID)),
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: UUID()), matchesSelectedContact: true)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedConversationReducerTeardownCompletionPreventsRepeatedTerminalTeardown() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        var seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .idle,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .inactive,
                        selfHasActiveDevice: false,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .unavailable
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])
        seededState.hadConnectedDevicePTTContinuity = true

        let completed = SelectedConversationReducer.reduce(
            state: seededState,
            event: .devicePTTTeardownCompleted(contactID: contactID)
        )
        let reconciled = SelectedConversationReducer.reduce(
            state: completed.state,
            event: .reconcileRequested
        )

        #expect(!completed.state.hadConnectedDevicePTTContinuity)
        #expect(completed.state.reconciliationAction == .none)
        #expect(completed.state.selectedConversationState.phase == .idle)
        #expect(reconciled.effects.isEmpty)
        #expect(reconciled.state.reconciliationAction == .none)
        #expect(reconciled.state.selectedConversationState.phase == .idle)
    }

    @Test func incomingBeepPrimaryActionUsesAcceptLabel() {
        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: SelectedConversationState(
                contactPresence: .connected,
                relationship: .incomingBeep(requestCount: 1),
                phase: .incomingBeep,
                statusMessage: "Blake wants to talk",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Accept")
        #expect(action.isEnabled)
        #expect(action.style == .accent)
    }

    @Test func idleSelectedConversationPrimaryActionUsesBeepLabel() {
        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: SelectedConversationState(
                relationship: .none,
                phase: .idle,
                statusMessage: "Blake is online",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Send Beep")
        #expect(action.isEnabled)
        #expect(action.style == .accent)
    }

    @Test func requestedPrimaryActionReenablesAndRestylesAfterCooldownExpires() {
        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: SelectedConversationState(
                relationship: .outgoingBeep(requestCount: 1),
                phase: .outgoingBeep,
                statusMessage: "Beep sent to Blake",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Beep Again")
        #expect(action.isEnabled)
        #expect(action.style == .accent)
    }

    @Test func requestedPrimaryActionShowsCooldownLabelWithoutTransientConnectButton() {
        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: SelectedConversationState(
                relationship: .outgoingBeep(requestCount: 1),
                phase: .outgoingBeep,
                statusMessage: "Beep sent to Blake",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: 12
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Beep again in 12s")
        #expect(action.isEnabled == false)
        #expect(action.style == .muted)
    }

    @Test func blockedRequestedPrimaryActionStaysDisabledDuringCooldown() {
        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: SelectedConversationState(
                relationship: .outgoingBeep(requestCount: 1),
                phase: .blockedByOtherSession,
                statusMessage: "Another session is active",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: 12
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Beep again in 12s")
        #expect(action.isEnabled == false)
        #expect(action.style == .muted)
    }

    @Test func selectedConversationReducerClearsStateOnDeselection() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let state = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.incomingBeep(requestCount: 1)),
            .baseStateUpdated(.incomingBeep),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false),
            .selectedContactChanged(nil)
        ])

        #expect(state.selection == nil)
        #expect(state.selectedConversationState.phase == .idle)
        #expect(state.reconciliationAction == .none)
    }

    @Test func beepThreadProjectionRepresentsSimultaneousIncomingAndOutgoingBeeps() {
        let relationship = ConversationStateMachine.beepThreadProjection(
            hasIncomingBeep: true,
            hasOutgoingBeep: true,
            requestCount: 2
        )

        #expect(relationship == .mutualBeep(requestCount: 2))
        #expect(relationship.hasIncomingBeep)
        #expect(relationship.hasOutgoingBeep)
        #expect(relationship.fallbackConversationState == .incomingBeep)
    }

    @Test func selectedConversationStateTreatsMutualBeepsAsAcceptableIncomingBeep() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .incomingBeep,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .mutualBeep(requestCount: 2)
        )

        #expect(state.phase == .incomingBeep)
        #expect(state.relationship == .mutualBeep(requestCount: 2))
        #expect(state.conversationState == .incomingBeep)
        #expect(state.statusMessage == "Blake wants to talk")
    }

    @MainActor
    @Test func transmissionInProgressBeginFailureClearsRemoteParticipantAndRetriesOnce() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)

        viewModel.handleFailedToBeginTransmitting(
            channelUUID,
            error: NSError(domain: PTChannelErrorDomain, code: 4)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.name == nil)
        #expect(pttClient.beginTransmitRequests == [channelUUID])
        #expect(viewModel.systemTransmitBeginRecoveryAttemptsByChannelUUID[channelUUID] == 1)
    }

    @Test func selectedConversationStateWaitsForSystemWakeActivationBeforeShowingReceiving() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            remoteParticipantSignalIsTransmitting: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            incomingWakeActivationState: .awaitingSystemActivation,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(selectedConversationState.phase == SelectedConversationPhase.waitingForPeer)
        #expect(selectedConversationState.detail == SelectedConversationDetail.waitingForPeer(reason: .systemWakeActivation))
        #expect(selectedConversationState.statusMessage == "Waiting for system audio activation...")
        #expect(selectedConversationState.canTransmitNow == false)
    }

    @Test func wakeExecutionReducerConfirmIncomingPushDoesNotDowngradeSystemActivation() {
        let contactID = UUID()
        let channelUUID = UUID()
        let provisionalPayload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "direct-quic"
        )
        let confirmedPayload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let activatedState = WakeExecutionReducer.reduce(
            state: WakeExecutionReducer.reduce(
                state: WakeExecutionSessionState(),
                event: .store(
                    PendingIncomingPTTPush(
                        contactID: contactID,
                        channelUUID: channelUUID,
                        payload: provisionalPayload,
                        activationState: .systemActivated
                    )
                ),
                maximumBufferedAudioChunks: 12
            ).state,
            event: .confirmIncomingPush(channelUUID: channelUUID, payload: confirmedPayload),
            maximumBufferedAudioChunks: 12
        ).state

        #expect(activatedState.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(activatedState.mediaSessionActivationMode(for: contactID) == .systemActivated)
        #expect(activatedState.shouldBufferAudioChunk(for: contactID) == false)
        #expect(activatedState.pendingIncomingPush?.payload.senderDeviceId == "peer-device")
    }

    @MainActor
    @Test func selectedConversationCoordinatorProjectsRemoteParticipantSignalReceivingState() {
        let contactID = UUID()
        let coordinator = SelectedConversationCoordinator()

        coordinator.send(
            .selectedContactChanged(
                SelectedConversationSelection(
                    contactID: contactID,
                    contactName: "Avery",
                    contactIsOnline: true
                )
            )
        )
        coordinator.send(.relationshipUpdated(.none))
        coordinator.send(.baseStateUpdated(.ready))
        coordinator.send(
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: TurboChannelStateResponse(
                        channelId: "channel",
                        selfUserId: "self",
                        peerUserId: "peer",
                        peerHandle: "@avery",
                        selfOnline: true,
                        peerOnline: true,
                        selfJoined: true,
                        peerJoined: true,
                        peerDeviceConnected: true,
                        hasIncomingBeep: false,
                        hasOutgoingBeep: false,
                        requestCount: 0,
                        activeTransmitterUserId: nil,
                        transmitLeaseExpiresAt: nil,
                        status: ConversationState.ready.rawValue,
                        canTransmit: true
                    )
                )
            )
        )
        coordinator.send(
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            )
        )
        coordinator.send(.localTransmitUpdated(.idle))
        coordinator.send(.remoteParticipantSignalTransmittingUpdated(true))
        coordinator.send(
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: UUID()),
                matchesSelectedContact: true
            )
        )

        #expect(coordinator.state.selectedConversationState.phase == .receiving)
    }

    @MainActor
    @Test func resetLocalDevStateClearsVisibleSessionErrorsAndTransientState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.remoteTransmittingContactIDs = [contactID]
        viewModel.remoteAudioSilenceTasks[contactID] = Task {}
        viewModel.statusMessage = "Join failed: stale channel"
        viewModel.diagnostics.record(.media, level: .error, message: "Old error")

        viewModel.resetLocalDevState(backendStatus: "Reconnecting as @blake...")

        #expect(viewModel.selectedContactId == nil)
        #expect(viewModel.contacts.isEmpty)
        #expect(viewModel.remoteTransmittingContactIDs.isEmpty)
        #expect(viewModel.remoteAudioSilenceTasks.isEmpty)
        #expect(viewModel.statusMessage == "Initializing...")
        #expect(viewModel.backendStatusMessage == "Reconnecting as @blake...")
        #expect(viewModel.diagnostics.latestError == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Old error") == false)
    }

    @MainActor
    @Test func resetLocalDevStateClearsSelectedConversationShortcutStateBeforeFreshSelection() async {
        let viewModel = PTTViewModel()
        let staleContactID = UUID()
        let freshContactID = UUID()

        viewModel.selectedConversationCoordinator.send(
            .selectedContactChanged(
                SelectedConversationSelection(
                    contactID: staleContactID,
                    contactName: "Blake",
                    contactIsOnline: true
                )
            )
        )
        viewModel.selectedConversationCoordinator.send(
            .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true)
        )
        viewModel.selectedConversationCoordinator.send(.relationshipUpdated(.none))
        viewModel.selectedConversationCoordinator.send(.baseStateUpdated(.idle))
        viewModel.selectedConversationCoordinator.send(.channelUpdated(nil))
        viewModel.selectedConversationCoordinator.send(
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            )
        )
        viewModel.selectedConversationCoordinator.send(.systemSessionUpdated(.none, matchesSelectedContact: false))

        await viewModel.selectedConversationCoordinator.handle(.joinRequested)

        #expect(viewModel.selectedConversationCoordinator.state.senderAutoJoinOnBeepAcceptanceArmed)

        viewModel.resetLocalDevState(backendStatus: "Reconnecting as @kai...")

        #expect(!viewModel.selectedConversationCoordinator.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(!viewModel.selectedConversationCoordinator.state.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(viewModel.selectedConversationCoordinator.state.selection == nil)

        viewModel.contacts = [
            Contact(
                id: freshContactID,
                name: "Kai",
                handle: "@kai",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-kai",
                remoteUserId: "user-kai"
            )
        ]

        guard let kai = viewModel.contacts.first else {
            Issue.record("missing fresh contact after reset")
            return
        }

        viewModel.selectContact(kai)

        let selectedConversationState = viewModel.selectedConversationState(for: freshContactID)

        #expect(selectedConversationState.phase == .idle)
        #expect(selectedConversationState.statusMessage == "Kai is online")
    }

    @Test func controlEventIngestorDispatchesEventIdOnce() {
        let contactID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let payload = DirectQuicReceiverPrewarmPayload(
            requestId: "request-1",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            reason: "direct-quic-activated",
            directQuicAttemptId: "attempt-1"
        )
        let envelope = ControlEventEnvelope.directQuicReceiverPrewarmAck(
            payload,
            contactID: contactID,
            localDeviceID: "local-device",
            attemptID: "attempt-1",
            timestamp: timestamp
        )
        let ready = ControlEventIngestorReducer.reduce(
            state: .initial,
            event: .directQuicAttemptUpdated(contactID: contactID, attemptID: "attempt-1")
        )

        let first = ControlEventIngestorReducer.reduce(
            state: ready.state,
            event: .ingest(envelope)
        )
        let duplicate = ControlEventIngestorReducer.reduce(
            state: first.state,
            event: .ingest(envelope)
        )

        #expect(first.effects == [.dispatch(envelope)])
        #expect(first.ignoredReason == nil)
        #expect(first.state.processedEventIDs == Set([envelope.eventID!]))
        #expect(duplicate.effects.isEmpty)
        #expect(duplicate.ignoredReason == .duplicateEvent(envelope.eventID!))
    }

    @Test func conversationOpenIntentParsesConversationDeepLink() {
        let url = URL(string: "beepbeep://conversation?handle=@avery&action=accept&beepId=beep-1&channelId=channel-1")!
        let intent = TurboIncomingLink.conversationOpenIntent(from: url)

        #expect(intent?.reference == "@avery")
        #expect(intent?.action == .accept)
        #expect(intent?.beepID == "beep-1")
        #expect(intent?.channelID == "channel-1")
    }

    @Test func liveActivityProjectionMapsSelectedConversationPhases() {
        let contact = Contact(
            id: UUID(),
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID()
        )
        let transmitting = SelectedConversationState(
            contactID: contact.id,
            contactName: contact.name,
            relationship: .none,
            detail: .transmitting,
            statusMessage: "Speaking",
            canTransmitNow: true
        )
        let receiving = SelectedConversationState(
            contactID: contact.id,
            contactName: contact.name,
            relationship: .none,
            detail: .receiving,
            statusMessage: "Listening",
            canTransmitNow: false
        )

        #expect(
            LiveConversationActivityProjection(
                contact: contact,
                selectedConversationState: transmitting,
                localDisplayName: "Mau",
                hasDevicePTTSession: true
            )?.phase == .speaking
        )
        #expect(
            LiveConversationActivityProjection(
                contact: contact,
                selectedConversationState: receiving,
                localDisplayName: "Mau",
                hasDevicePTTSession: true
            )?.speakerName == "Avery"
        )
    }

    @Test func liveActivityProjectionRequiresDevicePTTSession() {
        let contact = Contact(
            id: UUID(),
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID()
        )
        let ready = SelectedConversationState(
            contactID: contact.id,
            contactName: contact.name,
            relationship: .none,
            detail: .ready,
            statusMessage: "Connected",
            canTransmitNow: true
        )
        let receiving = SelectedConversationState(
            contactID: contact.id,
            contactName: contact.name,
            relationship: .none,
            detail: .receiving,
            statusMessage: "Listening",
            canTransmitNow: false
        )

        #expect(
            LiveConversationActivityProjection(
                contact: contact,
                selectedConversationState: ready,
                localDisplayName: "Mau",
                hasDevicePTTSession: false
            ) == nil
        )
        #expect(
            LiveConversationActivityProjection(
                contact: contact,
                selectedConversationState: receiving,
                localDisplayName: "Mau",
                hasDevicePTTSession: false
            ) == nil
        )
        #expect(
            LiveConversationActivityProjection(
                contact: contact,
                selectedConversationState: ready,
                localDisplayName: "Mau",
                hasDevicePTTSession: true
            )?.phase == .connected
        )
    }

    @MainActor
    @Test func refreshContactSummariesFailurePreservesExistingSelectedContactState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )
        let summary = TurboContactSummaryResponse(
            userId: "user-avery",
            handle: "@avery",
            displayName: "Avery",
            channelId: "channel-1",
            isOnline: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: true,
            requestCount: 1,
            isActiveConversation: false,
            badgeStatus: "outgoing-beep"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.trackContact(contactID)
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        await viewModel.refreshContactSummaries()

        #expect(viewModel.selectedContact?.id == contactID)
        #expect(viewModel.contacts.map(\.id) == [contactID])
        #expect(viewModel.contacts.first?.isOnline == true)
        #expect(viewModel.backendSyncCoordinator.state.syncState.contactSummaries[contactID] == summary)
    }

    @MainActor
    @Test func contactListSectionsBucketContactsByDerivedGroup() {
        let viewModel = PTTViewModel()
        let incomingID = UUID()
        let readyID = UUID()
        let requestedID = UUID()
        let offlineID = UUID()
        viewModel.contacts = [
            Contact(
                id: incomingID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            ),
            Contact(
                id: readyID,
                name: "Casey",
                handle: "@casey",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-casey"),
                backendChannelId: "channel-casey",
                remoteUserId: "user-casey"
            ),
            Contact(
                id: requestedID,
                name: "Drew",
                handle: "@drew",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-drew"),
                backendChannelId: "channel-drew",
                remoteUserId: "user-drew"
            ),
            Contact(
                id: offlineID,
                name: "Erin",
                handle: "@erin",
                isOnline: false,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-erin"),
                backendChannelId: "channel-erin",
                remoteUserId: "user-erin"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: incomingID,
                    summary: makeContactSummary(
                        channelId: "channel-blake",
                        handle: "@blake",
                        displayName: "Blake",
                        isOnline: true,
                        hasIncomingBeep: true,
                        requestCount: 2,
                        badgeStatus: "incoming",
                        membershipKind: "peer-only",
                        peerDeviceConnected: true
                    )
                ),
                BackendContactSummaryUpdate(
                    contactID: readyID,
                    summary: makeContactSummary(
                        channelId: "channel-casey",
                        handle: "@casey",
                        displayName: "Casey",
                        isOnline: true,
                        badgeStatus: "ready",
                        membershipKind: "both",
                        peerDeviceConnected: true
                    )
                ),
                BackendContactSummaryUpdate(
                    contactID: requestedID,
                    summary: makeContactSummary(
                        channelId: "channel-drew",
                        handle: "@drew",
                        displayName: "Drew",
                        isOnline: true,
                        hasOutgoingBeep: true,
                        requestCount: 1,
                        badgeStatus: "outgoing-beep",
                        membershipKind: "peer-only",
                        peerDeviceConnected: false
                    )
                ),
                BackendContactSummaryUpdate(
                    contactID: offlineID,
                    summary: makeContactSummary(
                        channelId: "channel-erin",
                        handle: "@erin",
                        displayName: "Erin",
                        isOnline: false,
                        badgeStatus: "offline",
                        membershipKind: "absent",
                        peerDeviceConnected: nil
                    )
                ),
            ])
        )

        let sections = viewModel.contactListSections

        #expect(sections.wantsToTalk.map { $0.contact.handle } == ["@blake"])
        #expect(sections.readyToTalk.map { $0.contact.handle } == ["@casey"])
        #expect(sections.outgoingBeep.map { $0.contact.handle } == ["@drew"])
        #expect(sections.contacts.map { $0.contact.handle } == ["@erin"])
        #expect(sections.wantsToTalk.first?.presentation.availabilityPill == .online)
        #expect(sections.readyToTalk.first?.presentation.availabilityPill == .online)
        #expect(sections.outgoingBeep.first?.presentation.availabilityPill == .online)
        #expect(sections.contacts.first?.presentation.availabilityPill == .offline)
    }

    @MainActor
    @Test func contactListKeepsSelectedConversationInSectionAndPinsOnlyActualActiveConversation() {
        let viewModel = PTTViewModel()
        let activeID = UUID()
        let selectedReadyID = UUID()
        viewModel.contacts = [
            Contact(
                id: activeID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-avery"),
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            ),
            Contact(
                id: selectedReadyID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            ),
        ]
        viewModel.selectedContactId = selectedReadyID
        viewModel.seedEngineJoinedConversationForTesting(contactID: activeID)
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: activeID,
                    summary: makeContactSummary(
                        channelId: "channel-avery",
                        handle: "@avery",
                        displayName: "Avery",
                        isOnline: true,
                        isActiveConversation: true,
                        badgeStatus: "ready",
                        membershipKind: "both",
                        peerDeviceConnected: true
                    )
                ),
                BackendContactSummaryUpdate(
                    contactID: selectedReadyID,
                    summary: makeContactSummary(
                        channelId: "channel-blake",
                        handle: "@blake",
                        displayName: "Blake",
                        isOnline: true,
                        badgeStatus: "ready",
                        membershipKind: "both",
                        peerDeviceConnected: true
                    )
                ),
            ])
        )

        let sections = viewModel.contactListSections

        #expect(viewModel.activeConversationContact?.handle == "@avery")
        #expect(sections.readyToTalk.map { $0.contact.handle } == ["@blake"])
        #expect(!sections.readyToTalk.map { $0.contact.handle }.contains("@avery"))
    }

    @MainActor
    @Test func activeConversationContactResolvesRestoredAppleSessionByChannelUUID() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-avery",
            remoteUserId: "user-avery"
        )
        viewModel.contacts = [contact]
        viewModel.handleRestoredChannel(channelUUID)

        #expect(viewModel.activeConversationContact?.id == contactID)
        #expect(viewModel.activeConversationContact?.handle == "@avery")
    }

    @MainActor
    @Test func emptyContactsDoesNotShowLoadingPlaceholderForRestoredAppleSessionAfterBackendRecovery() {
        let viewModel = PTTViewModel()
        let channelUUID = UUID()

        #expect(!viewModel.shouldShowContactsLoadingPlaceholder)

        viewModel.handleRestoredChannel(channelUUID)

        #expect(!viewModel.shouldShowContactsLoadingPlaceholder)
    }

    @MainActor
    @Test func restoredAppleSessionWithoutContactsShowsEndableSystemSessionSurface() {
        let viewModel = PTTViewModel()
        let channelUUID = UUID()

        viewModel.handleRestoredChannel(channelUUID)

        let contentView = ContentView(viewModel: viewModel)

        #expect(!viewModel.shouldShowContactsLoadingPlaceholder)
        #expect(!contentView.shouldShowContactsLoadingSurface())
        #expect(!contentView.shouldShowEmptyContactsSurface())
        #expect(contentView.shouldShowSystemSessionContactListSurface())
    }

    @MainActor
    @Test func endSystemSessionClearsRestoredAppleSessionWithoutContacts() {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let channelUUID = UUID()

        viewModel.handleRestoredChannel(channelUUID)

        viewModel.endSystemSession()

        #expect(pttClient.leaveRequests == [channelUUID])
        #expect(viewModel.systemSessionState == .none)
        #expect(!viewModel.isJoined)
    }

    @MainActor
    @Test func selectedConversationProjectionReadDoesNotMutateRequestedSelectionState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        viewModel.contacts = [contact]
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: "channel",
                        handle: "@blake",
                        displayName: "Blake",
                        hasOutgoingBeep: true,
                        requestCount: 1,
                        badgeStatus: "outgoing-beep"
                    )
                )
            ])
        )

        viewModel.selectContact(contact)
        #expect(viewModel.selectedConversationCoordinator.state.selectedConversationState.phase == .outgoingBeep)
        let stateAfterSelection = viewModel.selectedConversationCoordinator.state

        _ = viewModel.selectedConversationProjection(for: contactID)
        #expect(viewModel.selectedConversationCoordinator.state == stateAfterSelection)

        _ = viewModel.selectedConversationState(for: contactID)
        #expect(viewModel.selectedConversationCoordinator.state == stateAfterSelection)
    }

    @MainActor
    @Test func repeatedDetailFocusSelectionDoesNotRepublishSelectedFriendPrewarmHint() async throws {
        let contactID = UUID()
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
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-peer"
        )
        viewModel.contacts = [contact]

        viewModel.selectContact(contact, reason: "contact-list-focused-detail")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let firstSignalCount = client.sentSignalsForTesting().filter { $0.type == .selectedFriendPrewarm }.count

        viewModel.selectContact(contact, reason: "contact-list-focused-detail")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let secondSignalCount = client.sentSignalsForTesting().filter { $0.type == .selectedFriendPrewarm }.count

        #expect(firstSignalCount == 1)
        #expect(secondSignalCount == firstSignalCount)
        #expect(
            viewModel.diagnosticsTranscript.contains("blockReason=already-prewarmed-for-selected-contact")
        )
    }

    @MainActor
    @Test func disconnectTimeoutSelfHeals() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        viewModel.disconnectRecoveryDelayNanoseconds = 10_000_000
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        viewModel.performDisconnect()

        try await waitForScenario(
            "disconnect timeout self-heals",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "selected.disconnecting_timeout"
            }
            && viewModel.diagnostics.entries.contains {
                $0.message == "Recovering stuck disconnect"
            }
            && viewModel.conversationActionCoordinator.pendingAction == .none
        }

        #expect(pttClient.leaveRequests.count >= 2)
        #expect(viewModel.isJoined == false)
        #expect(viewModel.systemSessionState == .none)
    }

    @MainActor
    @Test func reconciledTeardownWithoutSystemSessionClearsPendingLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID

        await viewModel.runSelectedConversationEffect(.teardownDevicePTTSession(contactID: contactID))

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.isJoined == false)
        #expect(viewModel.systemSessionState == .none)
    }

    @MainActor
    @Test func reconciledTeardownCompletesWhenSystemSessionEndsBeforeJoinedFlagClears() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.conversationActionCoordinator.markReconciledTeardown(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.isJoined == false)
        #expect(viewModel.activeChannelId == nil)
        #expect(viewModel.systemSessionState == .none)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .idle)
    }

    @MainActor
    @Test func resolvingRestoredSystemSessionBindsContactAndFlushesDeferredTokenUpload() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.handleRestoredChannel(channelUUID)
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.pttSystemPolicyCoordinator.send(
            .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: nil)
        )

        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        let resolvedContactID = await viewModel.resolveRestoredSystemSessionIfPossible(trigger: "test")

        #expect(resolvedContactID == contactID)
        #expect(viewModel.selectedContactId == contactID)
        #expect(!viewModel.isJoined)
        #expect(viewModel.activeChannelId == nil)
        #expect(viewModel.activeConversationContact?.id == contactID)
        #expect(!viewModel.canBeginTransmit(for: contactID))
        #expect(
            viewModel.pttCoordinator.state.systemSessionState
                == .active(contactID: contactID, channelUUID: channelUUID)
        )
        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Resolved restored PTT channel contact without live transmit authority"
            }
        )
    }

    @MainActor
    @Test func resolvedRestoredSystemSessionDoesNotBeginTransmitBeforeFreshJoin() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.applicationStateOverride = .active
        viewModel.handleRestoredChannel(channelUUID)
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]

        _ = await viewModel.resolveRestoredSystemSessionIfPossible(trigger: "test")

        viewModel.beginTransmit()

        #expect(pttClient.beginTransmitRequests.isEmpty)
        #expect(viewModel.activeConversationContact?.id == contactID)
        #expect(!viewModel.isJoined)
        #expect(viewModel.activeChannelId == nil)
        #expect(viewModel.diagnosticsTranscript.contains("reason=not-joined"))

        viewModel.handleDidJoinChannel(channelUUID, reason: "fresh-join-test")
        try await waitForCondition(
            "fresh join clears restored-session quarantine",
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 20_000_000
        ) {
            !viewModel.isRestoredSystemSessionQuarantined(channelUUID: channelUUID)
                && viewModel.isJoined
                && viewModel.activeChannelId == contactID
                && viewModel.systemSessionMatches(contactID)
                && viewModel.selectedConversationCoordinator.state.devicePTT.systemSessionMatchesContact
        }
    }

    @MainActor
    @Test func unresolvedRestoredSystemSessionIsClearedAfterAuthoritativeRefresh() {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let restoredChannelUUID = UUID()
        let unrelatedContactID = UUID()
        viewModel.contacts = [
            Contact(
                id: unrelatedContactID,
                name: "Avery",
                handle: "@avery",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-avery"
            )
        ]
        viewModel.handleRestoredChannel(restoredChannelUUID)

        viewModel.clearUnresolvedRestoredSystemSessionIfNeeded(trigger: "test")

        #expect(pttClient.leaveRequests == [restoredChannelUUID])
        #expect(viewModel.isJoined == false)
        #expect(viewModel.activeChannelId == nil)
        #expect(viewModel.pttCoordinator.state.systemSessionState == .none)
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "ptt.restored_channel_without_backend_contact"
            }
        )
    }

    @MainActor
    @Test func resolvedRestoredSystemSessionIsNotClearedAfterAuthoritativeRefresh() {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let restoredChannelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: false,
                channelId: restoredChannelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.handleRestoredChannel(restoredChannelUUID)

        viewModel.clearUnresolvedRestoredSystemSessionIfNeeded(trigger: "test")

        #expect(pttClient.leaveRequests.isEmpty)
        #expect(!viewModel.isJoined)
        #expect(viewModel.activeChannelId == nil)
        #expect(
            viewModel.pttCoordinator.state.systemSessionState
                == .active(contactID: contactID, channelUUID: restoredChannelUUID)
        )
    }

    @MainActor
    @Test func unresolvedRestoredDidJoinLeavesWithoutApplyingApplePolicy() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let restoredChannelUUID = UUID()

        viewModel.handleRestoredChannel(restoredChannelUUID)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.isRestoredSystemSessionQuarantined(channelUUID: restoredChannelUUID))
        #expect(pttClient.transmissionModeUpdates.isEmpty)
        #expect(pttClient.serviceStatusUpdates.isEmpty)
        #expect(pttClient.accessoryButtonEventUpdates.isEmpty)

        viewModel.handleDidJoinChannel(restoredChannelUUID, reason: "restored-channel-ready")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.leaveRequests == [restoredChannelUUID])
        #expect(viewModel.pttCoordinator.state.systemSessionState == .none)
        #expect(!viewModel.isRestoredSystemSessionQuarantined(channelUUID: restoredChannelUUID))
        #expect(pttClient.transmissionModeUpdates.isEmpty)
        #expect(pttClient.serviceStatusUpdates.isEmpty)
        #expect(pttClient.accessoryButtonEventUpdates.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Ignoring unresolved restored PTT join"
            )
        )
    }

    @Test func expandedCallScreenRequestDoesNotShowCallScreenForIdleOnlineFriend() {
        let selectedConversationState = SelectedConversationState(
            relationship: .none,
            detail: .idle(isOnline: true),
            statusMessage: "Blake is online",
            canTransmitNow: false
        )

        #expect(!ConversationStateMachine.shouldShowCallScreen(
            selectedConversationState: selectedConversationState,
            requestedExpanded: true
        ))
    }

    @Test func expandedCallScreenRequestDoesNotShowCallScreenForBeepOnlyStates() {
        let outgoingState = SelectedConversationState(
            relationship: .outgoingBeep(requestCount: 1),
            detail: .outgoingBeep(requestCount: 1),
            statusMessage: "Beep sent to Blake",
            canTransmitNow: false
        )
        let incomingState = SelectedConversationState(
            relationship: .incomingBeep(requestCount: 1),
            detail: .incomingBeep(requestCount: 1),
            statusMessage: "Blake wants to talk",
            canTransmitNow: false
        )
        let friendReadyState = SelectedConversationState(
            relationship: .none,
            detail: .friendReady,
            statusMessage: "Blake is ready to connect",
            canTransmitNow: false
        )

        #expect(!ConversationStateMachine.shouldShowCallScreen(
            selectedConversationState: outgoingState,
            requestedExpanded: true
        ))
        #expect(!ConversationStateMachine.shouldShowCallScreen(
            selectedConversationState: incomingState,
            requestedExpanded: true
        ))
        #expect(ConversationStateMachine.shouldShowCallScreen(
            selectedConversationState: friendReadyState,
            requestedExpanded: true
        ))
        #expect(!ConversationStateMachine.shouldShowCallScreen(
            selectedConversationState: friendReadyState,
            requestedExpanded: false
        ))
    }

    @Test func pendingBeepSuppressesEstablishedCallScreenSessionClaim() {
        let contactID = UUID()
        let outgoingState = SelectedConversationState(
            relationship: .outgoingBeep(requestCount: 1),
            detail: .outgoingBeep(requestCount: 1),
            statusMessage: "Beep sent to Blake",
            canTransmitNow: false
        )
        let incomingState = SelectedConversationState(
            relationship: .incomingBeep(requestCount: 1),
            detail: .incomingBeep(requestCount: 1),
            statusMessage: "Blake wants to talk",
            canTransmitNow: false
        )
        let connectedState = SelectedConversationState(
            relationship: .none,
            detail: .ready,
            statusMessage: "Connected",
            canTransmitNow: true
        )

        #expect(!ConversationStateMachine.hasEstablishedCallScreenSessionClaim(
            contactID: contactID,
            selectedConversationState: outgoingState,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true
        ))
        #expect(!ConversationStateMachine.hasEstablishedCallScreenSessionClaim(
            contactID: contactID,
            selectedConversationState: incomingState,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true
        ))
        #expect(ConversationStateMachine.hasEstablishedCallScreenSessionClaim(
            contactID: contactID,
            selectedConversationState: connectedState,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true
        ))
    }

    @MainActor
    @Test func uiProjectionFlagsVisibleCallScreenForIdlePeer() {
        let projection = UIProjectionDiagnostics(
            route: "live",
            callScreenVisible: true,
            callScreenContactHandle: "@bau",
            callScreenRequestedExpanded: true,
            callScreenMinimized: false,
            primaryActionKind: "holdToTalk",
            primaryActionLabel: "Hold To Talk",
            primaryActionEnabled: true,
            selectedConversationPhase: "idle",
            selectedConversationStatus: "@bau is online"
        )

        let invariantIDs = projection.derivedInvariantCandidates.map(\.invariantID)

        #expect(invariantIDs.contains("ui.call_screen_visible_for_idle_peer"))
        #expect(invariantIDs.contains("ui.call_screen_talk_action_for_non_live_peer"))
    }

    @MainActor
    @Test func uiProjectionFlagsVisibleCallScreenForIncomingBeep() {
        let projection = UIProjectionDiagnostics(
            route: "live",
            callScreenVisible: true,
            callScreenContactHandle: "@mau",
            callScreenRequestedExpanded: true,
            callScreenMinimized: false,
            primaryActionKind: "connect",
            primaryActionLabel: "Accept",
            primaryActionEnabled: true,
            selectedConversationPhase: "incomingBeep",
            selectedConversationStatus: "Mau wants to talk"
        )

        let invariantIDs = projection.derivedInvariantCandidates.map(\.invariantID)

        #expect(invariantIDs.contains("ui.call_screen_visible_for_incoming_beep"))
    }

    @MainActor
    @Test func uiProjectionFlagsVisibleCallScreenForOutgoingBeep() {
        let projection = UIProjectionDiagnostics(
            route: "live",
            callScreenVisible: true,
            callScreenContactHandle: "@bau",
            callScreenRequestedExpanded: true,
            callScreenMinimized: false,
            primaryActionKind: "connect",
            primaryActionLabel: "Beep Again",
            primaryActionEnabled: false,
            selectedConversationPhase: "outgoingBeep",
            selectedConversationStatus: "Beep sent"
        )

        let invariantIDs = projection.derivedInvariantCandidates.map(\.invariantID)

        #expect(invariantIDs.contains("ui.call_screen_visible_for_outgoing_beep"))
    }

    @MainActor
    @Test func contactListSelectionDispositionFocusesDetailForNonCallContact() {
        let viewModel = PTTViewModel()
        let contact = Contact(
            id: UUID(),
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        viewModel.contacts = [contact]

        let contentView = ContentView(viewModel: viewModel)

        #expect(
            contentView.contactListSelectionDisposition(for: contact)
                == .focusDetail(selectReason: "contact-list-focused-detail")
        )
    }

    @MainActor
    @Test func contactListSelectionDispositionBypassesDetailForActiveCallContact() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        let contentView = ContentView(viewModel: viewModel)

        #expect(
            contentView.contactListSelectionDisposition(for: contact)
                == .openCall(selectReason: "contact-list-active-call")
        )
    }

    @MainActor
    @Test func requestedExpandedCallPresentationStateCollapsesFocusedDetailAndRestoresRequestedCall() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contentView = ContentView(viewModel: viewModel)

        #expect(
            contentView.requestedExpandedCallPresentationState(
                requestedContactID: contactID,
                focusedContactID: contactID,
                minimizedCallContactID: contactID
            ) == RequestedExpandedCallPresentationState(
                focusedContactID: nil,
                minimizedCallContactID: nil
            )
        )
    }

    @MainActor
    @Test func callScreenDismissalPresentationStateForLeavePreservesOtherMiniPlayer() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let otherMinimizedContactID = UUID()
        let contentView = ContentView(viewModel: viewModel)

        #expect(
            contentView.callScreenDismissalPresentationState(
                for: contactID,
                action: .leave,
                focusedContactID: UUID(),
                requestedExpandedCallContactID: contactID,
                minimizedCallContactID: otherMinimizedContactID
            ) == CallScreenDismissalPresentationState(
                focusedContactID: nil,
                requestedExpandedCallContactID: nil,
                minimizedCallContactID: otherMinimizedContactID
            )
        )
    }

    @MainActor
    @Test func incomingLeavePushKeepsLeaveBarrierAcrossDidLeaveAndRejectsStaleDidJoin() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "initial-join"
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.handleReceivedIncomingPTTPush(
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .leaveChannel,
                channelId: "channel-123",
                activeSpeaker: "@avery",
                activeSpeakerDisplayName: "Avery",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )

        #expect(viewModel.conversationActionCoordinator.pendingAction.isExplicitLeaveInFlight(for: contactID))
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Armed explicit leave barrier for incoming PTT leave push"
            }
        )

        viewModel.handleDidLeaveChannel(
            channelUUID,
            reason: .system(description: "PTChannelLeaveReason(rawValue: 2)")
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.pttCoordinator.state.isJoined == false)
        #expect(viewModel.isJoined == false)

        viewModel.handleDidJoinChannel(channelUUID, reason: "stale-rejoin")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(client.leaveRequests == [channelUUID])
        #expect(viewModel.pttCoordinator.state.isJoined == false)
        #expect(viewModel.isJoined == false)
        #expect(viewModel.statusMessage == "Disconnecting...")
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Ignoring stale PTT join after recent system leave"
            }
        )
    }

    @MainActor
    @Test func restoreDevicePTTSessionEffectIsIgnoredAfterRecentSystemLeave() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.markStaleSystemRejoinSuppression(
            channelUUID: channelUUID,
            contactID: contactID,
            reason: "recent-system-leave"
        )

        await viewModel.runSelectedConversationEffect(.restoreDevicePTTSession(contactID: contactID))

        #expect(client.joinRequests.isEmpty)
        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == nil)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Ignored automatic Device PTT restore after recent system leave"
            }
        )
    }

    @MainActor
    @Test func conversationContextCarriesRecentSystemLeaveRestoreBarrier() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-123",
            remoteUserId: "peer-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.markStaleSystemRejoinSuppression(
            channelUUID: channelUUID,
            contactID: contactID,
            reason: "recent-system-leave"
        )

        #expect(
            viewModel.conversationContext(for: contact).devicePTTRestoreBarrier
                == .recentSystemLeave(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    reason: "recent-system-leave"
                )
        )
    }
}
