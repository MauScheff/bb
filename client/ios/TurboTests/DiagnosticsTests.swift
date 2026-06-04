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
struct DiagnosticsTests {
    @Test func engineTraceRecordsAppBoundaryEventsAndReplays() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-a-b",
            remoteUserId: "remote-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
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
        let target = TransmitTarget(
            contactID: contactID,
            userID: "remote-user",
            deviceID: "peer-device",
            channelID: "channel-a-b",
            transmitID: "tx-trace"
        )

        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "trace-test")
        viewModel.syncEngineBeginTalkIntent(reason: "trace-test")
        viewModel.syncEngineBackendTransmitAccepted(target: target, source: "trace-test")

        let trace = viewModel.engineTrace
        let report = EngineTraceReplayer.replay(trace)

        #expect(trace.steps.count >= 3)
        #expect(trace.steps.contains { $0.source == "transmit-begin:trace-test" })
        #expect(trace.steps.contains { $0.source == "backend-transmit-accepted:trace-test" })
        #expect(report.passed)
        #expect(report.mismatches.isEmpty)
        #expect(report.finalSnapshot.transmit.activeEpoch?.transmitID == "tx-trace")
    }

    @Test func diagnosticsEnvelopeContainsReplayableEngineTrace() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.syncEngineBeginTalkIntent(reason: "diagnostics-trace-test")

        let envelope = viewModel.diagnosticsEnvelope(appVersion: "test-app")
        let trace = try #require(envelope.engineTrace)
        let replay = EngineTraceReplayer.replay(trace)
        let envelopeJSON = try PTTViewModel.structuredDiagnosticsEnvelopeJSON(envelope)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticsEnvelope.self, from: Data(envelopeJSON.utf8))
        let decodedTrace = try #require(decoded.engineTrace)

        #expect(replay.passed)
        #expect(!trace.steps.isEmpty)
        #expect(decodedTrace == trace)
        #expect(EngineTraceReplayer.replay(decodedTrace).passed)
    }

    @Test func diagnosticsUploadRequestContainsExtractableEngineTrace() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.syncEngineBeginTalkIntent(reason: "diagnostics-upload-trace-test")

        let payload = try viewModel.diagnosticsUploadRequest(
            deviceID: "device-upload-test",
            backendBaseURL: "https://example.test/s/turbo"
        )
        let marker = "STRUCTURED DIAGNOSTICS\n"
        let sectionStart = try #require(payload.transcript.range(of: marker)?.upperBound)
        let sectionTail = payload.transcript[sectionStart...]
        let sectionEnd = sectionTail.range(of: "\nSTATE TIMELINE\n")?.lowerBound ?? sectionTail.endIndex
        let sectionJSON = String(sectionTail[..<sectionEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(DiagnosticsEnvelope.self, from: Data(sectionJSON.utf8))
        let trace = try #require(envelope.engineTrace)
        let replay = EngineTraceReplayer.replay(trace)

        #expect(payload.deviceId == "device-upload-test")
        #expect(payload.backendBaseURL == "https://example.test/s/turbo")
        #expect(!trace.steps.isEmpty)
        #expect(replay.passed)
        #expect(replay.mismatches.isEmpty)
    }

    @Test func compactDiagnosticsUploadRequestKeepsReplayableEngineTrace() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        for index in 0..<260 {
            viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "compact-trace-\(index)")
        }
        viewModel.syncEngineBeginTalkIntent(reason: "compact-diagnostics-upload-trace-test")
        for index in 0..<180 {
            viewModel.diagnostics.record(
                .media,
                message: "diagnostic-entry-\(index)",
                metadata: ["index": "\(index)"]
            )
        }

        let fullPayload = try viewModel.diagnosticsUploadRequest(
            deviceID: "device-upload-test",
            backendBaseURL: "https://example.test/s/turbo",
            uploadMode: .full
        )
        let compactPayload = try viewModel.diagnosticsUploadRequest(
            deviceID: "device-upload-test",
            backendBaseURL: "https://example.test/s/turbo",
            uploadMode: .compact
        )
        let minimalPayload = try viewModel.diagnosticsUploadRequest(
            deviceID: "device-upload-test",
            backendBaseURL: "https://example.test/s/turbo",
            uploadMode: .minimal
        )
        let marker = "STRUCTURED DIAGNOSTICS\n"
        let sectionStart = try #require(compactPayload.transcript.range(of: marker)?.upperBound)
        let sectionTail = compactPayload.transcript[sectionStart...]
        let sectionEnd = sectionTail.range(of: "\nSTATE TIMELINE\n")?.lowerBound ?? sectionTail.endIndex
        let sectionJSON = String(sectionTail[..<sectionEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let minimalSectionStart = try #require(minimalPayload.transcript.range(of: marker)?.upperBound)
        let minimalSectionTail = minimalPayload.transcript[minimalSectionStart...]
        let minimalSectionEnd = minimalSectionTail.range(of: "\nSTATE TIMELINE\n")?.lowerBound ?? minimalSectionTail.endIndex
        let minimalSectionJSON = String(minimalSectionTail[..<minimalSectionEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(DiagnosticsEnvelope.self, from: Data(sectionJSON.utf8))
        let minimalEnvelope = try decoder.decode(DiagnosticsEnvelope.self, from: Data(minimalSectionJSON.utf8))
        let trace = try #require(envelope.engineTrace)
        let minimalTrace = try #require(minimalEnvelope.engineTrace)
        let replay = EngineTraceReplayer.replay(trace)
        let minimalReplay = EngineTraceReplayer.replay(minimalTrace)

        #expect(compactPayload.transcript.contains("STRUCTURED DIAGNOSTICS"))
        #expect(!compactPayload.transcript.contains("PERSISTED DIAGNOSTICS TAIL"))
        #expect(compactPayload.transcript.count < fullPayload.transcript.count)
        #expect(minimalPayload.transcript.count < compactPayload.transcript.count)
        #expect(trace.steps.count <= 120)
        #expect(minimalTrace.steps.count <= 48)
        #expect(!trace.steps.isEmpty)
        #expect(!minimalTrace.steps.isEmpty)
        #expect(replay.passed)
        #expect(minimalReplay.passed)
        #expect(replay.mismatches.isEmpty)
        #expect(minimalReplay.mismatches.isEmpty)
    }

    @Test func diagnosticsPreparedUploadDownshiftsOversizedCompactPayloadBeforeNetwork() throws {
        let viewModel = PTTViewModel()
        let largeStateValue = String(repeating: "x", count: 16_000)
        for index in 0..<12 {
            var fields = viewModel.diagnosticsStateFields
            fields["oversizedDiagnosticsField"] = largeStateValue
            fields["oversizedDiagnosticsIndex"] = "\(index)"
            viewModel.diagnostics.captureState(
                reason: "oversized-diagnostics-\(index)",
                fields: fields
            )
        }

        let prepared = try viewModel.diagnosticsPreparedUploadRequest(
            deviceID: "device-upload-test",
            backendBaseURL: "https://example.test/s/turbo",
            preferredUploadMode: .compact
        )

        #expect(prepared.uploadMode == .minimal)
        #expect(prepared.requestBodySizeBytes <= DiagnosticsUploadMode.minimal.maximumRequestBodyBytes)
        #expect(prepared.localFallbackReasons.contains {
            $0.contains("compact")
                && $0.contains("\(DiagnosticsUploadMode.compact.maximumRequestBodyBytes)")
        })
        #expect(prepared.request.transcript.contains("STRUCTURED DIAGNOSTICS"))
    }

    @Test func diagnosticsPreparedUploadFallsBackToTinyWhenMinimalIsOversized() throws {
        let viewModel = PTTViewModel()
        let largeStateValue = String(repeating: "x", count: 90_000)
        for index in 0..<12 {
            var fields = viewModel.diagnosticsStateFields
            fields["oversizedDiagnosticsField"] = largeStateValue
            fields["oversizedDiagnosticsIndex"] = "\(index)"
            viewModel.diagnostics.captureState(
                reason: "oversized-diagnostics-\(index)",
                fields: fields
            )
        }

        let prepared = try viewModel.diagnosticsPreparedUploadRequest(
            deviceID: "device-upload-test",
            backendBaseURL: "https://example.test/s/turbo",
            preferredUploadMode: .compact
        )

        #expect(prepared.uploadMode == .tiny)
        #expect(prepared.requestBodySizeBytes <= DiagnosticsUploadMode.tiny.maximumRequestBodyBytes)
        #expect(prepared.localFallbackReasons.contains {
            $0.contains("minimal")
                && $0.contains("\(DiagnosticsUploadMode.minimal.maximumRequestBodyBytes)")
        })
        #expect(prepared.request.transcript.contains("STRUCTURED DIAGNOSTICS"))
        #expect(!prepared.request.transcript.contains("STATE SNAPSHOT"))
        #expect(prepared.request.selectedHandle == nil)
        let marker = "STRUCTURED DIAGNOSTICS\n"
        let sectionStart = try #require(prepared.request.transcript.range(of: marker)?.upperBound)
        let sectionTail = prepared.request.transcript[sectionStart...]
        let sectionEnd = sectionTail.range(of: "\nSTATE TIMELINE\n")?.lowerBound ?? sectionTail.endIndex
        let sectionJSON = String(sectionTail[..<sectionEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(DiagnosticsEnvelope.self, from: Data(sectionJSON.utf8))
        #expect(envelope.engineTrace == nil)
        #expect(envelope.stateCaptures.isEmpty)
        #expect(envelope.reducerTransitionReports.isEmpty)
    }

    @Test func diagnosticsTinyUploadUsesEmergencySnapshotForNoisyReports() throws {
        let viewModel = PTTViewModel()
        let largeValue = String(repeating: "x", count: 50_000)
        for index in 0..<8 {
            viewModel.diagnostics.record(
                .media,
                message: "Noisy media diagnostic \(index)",
                metadata: [
                    "oversized": largeValue,
                    "index": "\(index)",
                ]
            )
        }

        let prepared = try viewModel.diagnosticsPreparedUploadRequest(
            deviceID: "device-upload-test",
            backendBaseURL: "https://example.test/s/turbo",
            preferredUploadMode: .compact
        )

        #expect(prepared.uploadMode == .tiny)
        #expect(prepared.requestBodySizeBytes <= DiagnosticsUploadMode.tiny.maximumRequestBodyBytes)
        #expect(prepared.request.snapshot.count < 8_000)
        #expect(!prepared.request.transcript.contains("STATE SNAPSHOT"))
        #expect(!prepared.request.transcript.contains(largeValue))
    }

    @Test func diagnosticsUploadModesUseBoundedFallbackTimeoutsAndPayloadBudgets() {
        #expect(DiagnosticsUploadMode.full.timeoutInterval == 12)
        #expect(DiagnosticsUploadMode.compact.timeoutInterval == 8)
        #expect(DiagnosticsUploadMode.minimal.timeoutInterval == 5)
        #expect(DiagnosticsUploadMode.tiny.timeoutInterval == 4)
        #expect(
            DiagnosticsUploadMode.full.timeoutInterval
                > DiagnosticsUploadMode.compact.timeoutInterval
        )
        #expect(
            DiagnosticsUploadMode.compact.timeoutInterval
                > DiagnosticsUploadMode.minimal.timeoutInterval
        )
        #expect(
            DiagnosticsUploadMode.minimal.timeoutInterval
                > DiagnosticsUploadMode.tiny.timeoutInterval
        )
        #expect(DiagnosticsUploadMode.full.maximumRequestBodyBytes == 900_000)
        #expect(DiagnosticsUploadMode.compact.maximumRequestBodyBytes == 240_000)
        #expect(DiagnosticsUploadMode.minimal.maximumRequestBodyBytes == 80_000)
        #expect(DiagnosticsUploadMode.tiny.maximumRequestBodyBytes == 40_000)
        #expect(DiagnosticsUploadMode.compact.defaultEngineTraceStepLimit == 120)
        #expect(DiagnosticsUploadMode.minimal.defaultEngineTraceStepLimit == 48)
        #expect(DiagnosticsUploadMode.tiny.defaultEngineTraceStepLimit == nil)
    }

    @MainActor
    @Test func automaticDiagnosticsPublishDefersDuringLiveMedia() {
        let viewModel = PTTViewModel()
        #expect(viewModel.automaticDiagnosticsPublishPreferredUploadMode == .tiny)
        #expect(!viewModel.shouldDeferAutomaticDiagnosticsPublishForLiveMedia)

        viewModel.uiProjectionDiagnostics = UIProjectionDiagnostics(
            route: "live",
            callScreenVisible: true,
            callScreenContactHandle: "@blake",
            callScreenRequestedExpanded: true,
            callScreenMinimized: false,
            primaryActionKind: "holdToTalk",
            primaryActionLabel: "Hold To Talk",
            primaryActionEnabled: true,
            selectedConversationPhase: "ready",
            selectedConversationStatus: "Connected"
        )
        #expect(viewModel.shouldDeferAutomaticDiagnosticsPublishForLiveMedia)
        #expect(viewModel.automaticDiagnosticsPublishDeferralReason == .callScreen)

        viewModel.uiProjectionDiagnostics = UIProjectionDiagnostics(
            route: "live",
            callScreenVisible: true,
            callScreenContactHandle: nil,
            callScreenRequestedExpanded: true,
            callScreenMinimized: false,
            primaryActionKind: "holdToTalk",
            primaryActionLabel: "Hold To Talk",
            primaryActionEnabled: true,
            selectedConversationPhase: "ready",
            selectedConversationStatus: "Connected"
        )
        #expect(viewModel.shouldDeferAutomaticDiagnosticsPublishForLiveMedia)
        #expect(viewModel.automaticDiagnosticsPublishDeferralReason == .callScreen)

        viewModel.uiProjectionDiagnostics = UIProjectionDiagnostics(
            route: "live",
            callScreenVisible: false,
            callScreenContactHandle: nil,
            callScreenRequestedExpanded: false,
            callScreenMinimized: false,
            primaryActionKind: nil,
            primaryActionLabel: nil,
            primaryActionEnabled: nil,
            selectedConversationPhase: "none",
            selectedConversationStatus: "none"
        )
        #expect(!viewModel.shouldDeferAutomaticDiagnosticsPublishForLiveMedia)

        viewModel.isPTTAudioSessionActive = true
        #expect(viewModel.shouldDeferAutomaticDiagnosticsPublishForLiveMedia)

        viewModel.isPTTAudioSessionActive = false
        viewModel.markRemoteAudioActivity(for: UUID(), source: .transmitStartSignal)
        #expect(viewModel.shouldDeferAutomaticDiagnosticsPublishForLiveMedia)
    }

    @MainActor
    @Test func firstAudioPlaybackAckWithoutExpectationRecordsContractViolation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.handleAudioPlaybackStartedAck(
            TurboAudioPlaybackStartedPayload(
                ackId: "ack-1",
                channelId: "channel-1",
                senderDeviceId: "sender-device",
                receiverDeviceId: "receiver-device",
                transport: "direct-quic",
                transportDigest: "digest-1",
                encryptedSequenceNumber: nil
            ),
            contactID: contactID,
            source: .directQuicDataChannel
        )

        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.first_audio_ack_without_expectation"
                    && $0.metadata["contractKind"] == "precondition"
                    && $0.metadata["ackId"] == "ack-1"
            }
        )
    }

    @MainActor
    @Test func mediaSessionContractEventRecordsInvariantViolation() {
        let viewModel = PTTViewModel()

        viewModel.recordMediaSessionEvent(
            "Dropped stale outbound audio transport payload",
            metadata: [
                "contractKind": DiagnosticsContractKind.liveness.rawValue,
                "invariantID": "media.outbound_audio_transport_backpressure_drop",
                "maximumPendingPayloads": "3",
                "pendingPayloadCount": "3",
                "reason": "outbound-transport-backpressure",
                "scope": DiagnosticsInvariantScope.local.rawValue,
            ]
        )

        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "media.outbound_audio_transport_backpressure_drop"
                    && $0.scope == .local
                    && $0.metadata["contractKind"] == "liveness"
                    && $0.metadata["pendingPayloadCount"] == "3"
            }
        )
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.subsystem == .media
                    && $0.level == .error
                    && $0.message == "Contract liveness failed: Dropped stale outbound audio transport payload"
                    && $0.metadata["invariantID"] == "media.outbound_audio_transport_backpressure_drop"
            }
        )
    }

    @MainActor
    @Test func staleMediaRelayControlFrameRecordsPeerBindingContract() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let frame = try TurboMediaRelayControlFrame.receiverPrewarmRequest(
            DirectQuicReceiverPrewarmPayload(
                requestId: "request-1",
                channelId: "stale-channel",
                fromDeviceId: "stale-device",
                reason: "test",
                directQuicAttemptId: "attempt-1"
            )
        )

        await viewModel.handleIncomingMediaRelayControlFrame(
            frame,
            contactID: contactID,
            channelID: "current-channel",
            peerDeviceID: "current-device"
        )

        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "media.relay_control_frame_mismatch"
                    && $0.metadata["contractName"] == "media.relay_control_frame_matches_current_peer"
                    && $0.metadata["expectedChannelId"] == "current-channel"
                    && $0.metadata["receivedChannelId"] == "stale-channel"
                    && $0.metadata["requestId"] == "request-1"
            }
        )
    }

    @MainActor
    @Test func incomingAudioChunkGapRecordsLivenessContractDuringActiveReceiveEpoch() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.remoteAudioChunkContinuityGapNanoseconds = 250_000_000
        viewModel.receiveExecutionCoordinator.effectHandler = { _ in }
        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.recordIncomingAudioContinuityContractIfNeeded(
            contactID: contactID,
            channelID: "channel-1",
            incomingAudioTransport: .directQuic,
            nowNanoseconds: 1_000_000_000
        )
        viewModel.recordIncomingAudioContinuityContractIfNeeded(
            contactID: contactID,
            channelID: "channel-1",
            incomingAudioTransport: .directQuic,
            nowNanoseconds: 1_400_000_000
        )

        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "media.incoming_audio_chunk_gap"
                    && $0.metadata["contractKind"] == "liveness"
                    && $0.metadata["gapMilliseconds"] == "400"
                    && $0.metadata["incomingTransport"] == "direct-quic"
            }
        )
    }

    @MainActor
    @Test func incomingAudioChunkGapDiagnosticsAreBudgetedDuringActiveReceiveEpoch() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.remoteAudioChunkContinuityGapNanoseconds = 250_000_000
        viewModel.receiveExecutionCoordinator.effectHandler = { _ in }
        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.recordIncomingAudioContinuityContractIfNeeded(
            contactID: contactID,
            channelID: "channel-1",
            incomingAudioTransport: .mediaRelayPacket,
            nowNanoseconds: 1_000_000_000
        )
        viewModel.recordIncomingAudioContinuityContractIfNeeded(
            contactID: contactID,
            channelID: "channel-1",
            incomingAudioTransport: .mediaRelayPacket,
            nowNanoseconds: 1_400_000_000
        )
        viewModel.recordIncomingAudioContinuityContractIfNeeded(
            contactID: contactID,
            channelID: "channel-1",
            incomingAudioTransport: .mediaRelayPacket,
            nowNanoseconds: 1_800_000_000
        )

        let chunkGapViolations = viewModel.diagnostics.invariantViolations.filter {
            $0.invariantID == "media.incoming_audio_chunk_gap"
                && $0.metadata["incomingTransport"] == "media-relay-packet"
        }
        let suppressionNotices = viewModel.diagnostics.entries.filter {
            $0.message == "Suppressing repetitive incoming audio chunk gap diagnostics"
                && $0.metadata["incomingTransport"] == "media-relay-packet"
        }

        #expect(chunkGapViolations.count == 1)
        #expect(suppressionNotices.count == 1)
        #expect(suppressionNotices.first?.metadata["detailedReportLimit"] == "1")
    }

    @MainActor
    @Test func relayWebSocketIncomingAudioChunkGapUsesOrderedFallbackThreshold() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.remoteAudioChunkContinuityGapNanoseconds = 250_000_000
        viewModel.receiveExecutionCoordinator.effectHandler = { _ in }
        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.recordIncomingAudioContinuityContractIfNeeded(
            contactID: contactID,
            channelID: "channel-1",
            incomingAudioTransport: .relayWebSocket,
            nowNanoseconds: 1_000_000_000
        )
        viewModel.recordIncomingAudioContinuityContractIfNeeded(
            contactID: contactID,
            channelID: "channel-1",
            incomingAudioTransport: .relayWebSocket,
            nowNanoseconds: 1_886_000_000
        )

        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "media.incoming_audio_chunk_gap"
                    && $0.metadata["incomingTransport"] == "relay-websocket"
            }
        )

        viewModel.recordIncomingAudioContinuityContractIfNeeded(
            contactID: contactID,
            channelID: "channel-1",
            incomingAudioTransport: .relayWebSocket,
            nowNanoseconds: 2_987_000_000
        )

        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "media.incoming_audio_chunk_gap"
                    && $0.metadata["incomingTransport"] == "relay-websocket"
                    && $0.metadata["gapMilliseconds"] == "1101"
                    && $0.metadata["thresholdMilliseconds"] == "1000"
            }
        )
    }

    @MainActor
    @Test func orderedFallbackContinuityThresholdsAreTransportSpecific() {
        let viewModel = PTTViewModel()

        #expect(viewModel.incomingAudioChunkContinuityGapNanoseconds(for: .directQuic) == 350_000_000)
        #expect(viewModel.incomingAudioChunkContinuityGapNanoseconds(for: .mediaRelayPacket) == 350_000_000)
        #expect(viewModel.incomingAudioChunkContinuityGapNanoseconds(for: .mediaRelayTcp) == 700_000_000)
        #expect(viewModel.incomingAudioChunkContinuityGapNanoseconds(for: .relayWebSocket) == 1_000_000_000)
    }

    @MainActor
    @Test func incomingAudioSequenceGapRecordsLivenessContractDuringActiveReceiveEpoch() {
        let orderedTransports: [IncomingAudioPayloadTransport] = [.mediaRelayTcp, .relayWebSocket]
        let packetTransports: [IncomingAudioPayloadTransport] = [.directQuic, .mediaRelayPacket]

        for transport in orderedTransports {
            let viewModel = PTTViewModel()
            let contactID = UUID()
            viewModel.receiveExecutionCoordinator.effectHandler = { _ in }
            viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
            viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

            viewModel.recordIncomingAudioSequenceContractIfNeeded(
                contactID: contactID,
                channelID: "channel-1",
                incomingAudioTransport: transport,
                sequenceNumber: 1
            )
            viewModel.recordIncomingAudioSequenceContractIfNeeded(
                contactID: contactID,
                channelID: "channel-1",
                incomingAudioTransport: transport,
                sequenceNumber: 3
            )

            #expect(
                viewModel.diagnostics.invariantViolations.contains {
                    $0.invariantID == "media.incoming_audio_sequence_gap"
                        && $0.metadata["contractKind"] == "liveness"
                        && $0.metadata["previousSequenceNumber"] == "1"
                        && $0.metadata["sequenceNumber"] == "3"
                        && $0.metadata["missingSequenceCount"] == "1"
                        && $0.metadata["incomingTransport"] == transport.diagnosticsValue
                }
            )
        }

        for transport in packetTransports {
            let viewModel = PTTViewModel()
            let contactID = UUID()
            viewModel.receiveExecutionCoordinator.effectHandler = { _ in }
            viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
            viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

            viewModel.recordIncomingAudioSequenceContractIfNeeded(
                contactID: contactID,
                channelID: "channel-1",
                incomingAudioTransport: transport,
                sequenceNumber: 1
            )
            viewModel.recordIncomingAudioSequenceContractIfNeeded(
                contactID: contactID,
                channelID: "channel-1",
                incomingAudioTransport: transport,
                sequenceNumber: 3
            )

            #expect(
                !viewModel.diagnostics.invariantViolations.contains {
                    $0.invariantID == "media.incoming_audio_sequence_gap"
                        && $0.metadata["incomingTransport"] == transport.diagnosticsValue
                }
            )
        }
    }

    @MainActor
    @Test func missingFirstAudioPlaybackAckRecordsInvariant() async throws {
        let previousRelayOnlyForced = TurboDirectPathDebugOverride.isRelayOnlyForced()
        TurboDirectPathDebugOverride.setRelayOnlyForced(true)
        defer {
            TurboDirectPathDebugOverride.setRelayOnlyForced(previousRelayOnlyForced)
        }

        let viewModel = PTTViewModel()
        viewModel.firstAudioPlaybackAckTimeoutNanoseconds = 20_000_000
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.enableSentSignalCaptureForTesting()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "sender-user",
            mode: "cloud"
        )
        let contactID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        viewModel.seedEngineActiveTransmitForTesting(
            contactID: contactID,
            channelID: "channel-1",
            localDeviceID: client.deviceID,
            peerDeviceID: "peer-device"
        )

        viewModel.configureOutgoingAudioRoute(target: target)
        let sendAudioChunk = try #require(viewModel.mediaRuntime.sendAudioChunk)
        try await sendAudioChunk("payload-1")

        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.first_audio_playback_ack_missing"
                    && $0.metadata["contractName"] == "media.first_audio_playback_ack_arrives_before_timeout"
                    && $0.metadata["receiverDeviceId"] == "peer-device"
                    && $0.metadata["transportDigest"] == AudioChunkPayloadCodec.transportDigest("payload-1")
            }
        )
        viewModel.clearFirstAudioPlaybackAckExpectations()
    }

    @MainActor
    @Test func outgoingAudioRouteRejectsMismatchedTransmitTargetContract() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "sender-user",
            mode: "cloud"
        )
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "peer-user"
            )
        ]

        viewModel.configureOutgoingAudioRoute(
            target: TransmitTarget(
                contactID: contactID,
                userID: "other-user",
                deviceID: client.deviceID,
                channelID: "other-channel"
            )
        )

        #expect(viewModel.mediaRuntime.sendAudioChunk == nil)
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "identity.transmit_target_mismatch"
                    && $0.metadata["contractName"] == "identity.transmit_target_matches_contact"
                    && $0.metadata["expectedChannelId"] == "channel-1"
                    && $0.metadata["targetChannelId"] == "other-channel"
                    && $0.metadata["contactFound"] == "true"
            }
        )
    }

    @Test func audioPacketDiagnosticsDebugOverrideSupportsStoredLaunchAndEnvironmentFlags() throws {
        let suiteName = "TurboTests.audio-packet-diagnostics-override.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(
            !TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled(
                arguments: [],
                environment: [:],
                defaults: defaults
            )
        )

        TurboAudioDiagnosticsDebugOverride.setPacketMetadataEnabled(true, defaults: defaults)
        #expect(
            TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled(
                arguments: [],
                environment: [:],
                defaults: defaults
            )
        )
        #expect(
            !TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled(
                arguments: [
                    TurboAudioDiagnosticsDebugOverride.packetMetadataLaunchArgument,
                    "false",
                ],
                environment: [:],
                defaults: defaults
            )
        )
        #expect(
            TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled(
                arguments: [],
                environment: [
                    TurboAudioDiagnosticsDebugOverride.packetMetadataEnvironmentKey: "true",
                ],
                defaults: defaults
            )
        )
    }

    @Test func audioPacketDiagnosticsDebugOverrideIsIgnoredForProductionLikeBuilds() throws {
        let suiteName = "TurboTests.audio-packet-diagnostics-production-like.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        TurboAudioDiagnosticsDebugOverride.setPacketMetadataEnabled(true, defaults: defaults)

        #expect(
            !TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled(
                arguments: [TurboAudioDiagnosticsDebugOverride.packetMetadataLaunchArgument],
                environment: [
                    TurboAudioDiagnosticsDebugOverride.packetMetadataEnvironmentKey: "true",
                ],
                defaults: defaults,
                allowDebugOverride: false
            )
        )
    }

    @Test func callScreenStatisticsVisibilityRecognizesTestFlightReceipt() {
        #expect(
            TurboCallScreenStatisticsVisibilityFlag.isTestFlightReceipt(
                appStoreReceiptURL: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/app/StoreKit/sandboxReceipt")
            )
        )
        #expect(
            !TurboCallScreenStatisticsVisibilityFlag.isTestFlightReceipt(
                appStoreReceiptURL: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/app/StoreKit/receipt")
            )
        )
    }

    @Test func callScreenStatisticsVisibilityUsesBundleReceiptURLByDefault() {
        #expect(
            TurboCallScreenStatisticsVisibilityFlag.isEnabledForProductionLikeBuild(
                appStoreReceiptURL: nil,
                appStoreReceiptURLProvider: { _ in
                    URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/app/StoreKit/sandboxReceipt")
                }
            )
        )
        #expect(
            !TurboCallScreenStatisticsVisibilityFlag.isEnabledForProductionLikeBuild(
                appStoreReceiptURL: nil,
                appStoreReceiptURLProvider: { _ in
                    URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/app/StoreKit/receipt")
                }
            )
        )
    }

    @Test func controlCommandTransportDebugOverrideIsIgnoredForProductionLikeBuilds() throws {
        let suiteName = "TurboTests.control-command-transport-production-like.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        TurboControlCommandTransportDebugOverride.setPolicy(.httpOnly, defaults: defaults)

        #expect(
            TurboControlCommandTransportDebugOverride.policy(
                arguments: [
                    TurboControlCommandTransportDebugOverride.launchArgument,
                    TurboControlCommandTransportPolicy.httpOnly.rawValue,
                ],
                environment: [
                    TurboControlCommandTransportDebugOverride.environmentKey:
                        TurboControlCommandTransportPolicy.httpOnly.rawValue,
                ],
                defaults: defaults,
                allowDebugOverride: false
            ) == nil
        )
    }

    @Test func callScreenBackgroundAnimationFlagDefaultsOffAndSupportsOverrides() throws {
        let suiteName = "TurboTests.call-screen-background-animation-flag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(
            !TurboCallScreenBackgroundAnimationFlag.isEnabled(
                arguments: [],
                environment: [:],
                defaults: defaults
            )
        )

        TurboCallScreenBackgroundAnimationFlag.setEnabled(true, defaults: defaults)
        #expect(
            TurboCallScreenBackgroundAnimationFlag.isEnabled(
                arguments: [],
                environment: [:],
                defaults: defaults
            )
        )
        #expect(
            !TurboCallScreenBackgroundAnimationFlag.isEnabled(
                arguments: [
                    TurboCallScreenBackgroundAnimationFlag.launchArgument,
                    "false",
                ],
                environment: [:],
                defaults: defaults
            )
        )
        #expect(
            TurboCallScreenBackgroundAnimationFlag.isEnabled(
                arguments: [TurboCallScreenBackgroundAnimationFlag.launchArgument],
                environment: [:],
                defaults: defaults
            )
        )

        TurboCallScreenBackgroundAnimationFlag.clear(defaults: defaults)
        #expect(
            TurboCallScreenBackgroundAnimationFlag.isEnabled(
                arguments: [],
                environment: [
                    TurboCallScreenBackgroundAnimationFlag.environmentKey: "true",
                ],
                defaults: defaults
            )
        )
    }

    @MainActor
    @Test func directQuicActivationWithoutNominationIsDiagnosticInfoNotError() async {
        let contactID = UUID()
        let viewModel = PTTViewModel()

        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )

        await viewModel.activateDirectQuicMediaPath(
            for: contactID,
            attemptID: "attempt-1"
        )

        #expect(viewModel.diagnostics.latestError == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Direct QUIC activation deferred because no nominated path is available yet"
            )
        )
        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID) == false)
    }

    @Test func contactSummaryDecodeFailsWithoutNestedContract() {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingBeep": false,
              "hasOutgoingBeep": false,
              "requestCount": 0,
              "isActiveConversation": true,
              "badgeStatus": "ready"
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)
            Issue.record("Expected TurboContactSummaryResponse decode to fail without nested contract")
        } catch {
        }
    }

    @Test func channelStateDecodeFailsWithoutNestedContract() {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@blake",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingBeep": false,
              "hasOutgoingBeep": false,
              "requestCount": 0,
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)
            Issue.record("Expected TurboChannelStateResponse decode to fail without nested contract")
        } catch {
        }
    }

    @Test func channelReadinessDecodeFailsWithoutNestedContract() {
        let data = Data(
            """
            {
              "channelId": "channel",
              "peerUserId": "peer",
              "selfHasActiveDevice": true,
              "peerHasActiveDevice": true,
              "activeTransmitterUserId": "peer",
              "activeTransmitExpiresAt": null,
              "status": "ready"
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboChannelReadinessResponse.self, from: data)
            Issue.record("Expected TurboChannelReadinessResponse decode to fail without readiness contract")
        } catch {
        }
    }

    @Test func backendChannelContractManifestExamplesDecodeAndCoverVariants() throws {
        let manifest = try backendContractManifest()
        let decoder = JSONDecoder()

        let expectedBeepThreadProjectionKinds = try backendContractVariants(manifest, "beepThreadProjection")
        let expectedMembershipKinds = try backendContractVariants(manifest, "membership")
        let expectedConversationStatusKinds = try backendContractVariants(manifest, "conversationStatus")
        let expectedReadinessKinds = try backendContractVariants(manifest, "readiness")
        let expectedAudioReadinessKinds = try backendContractVariants(manifest, "audioReadiness")
        let expectedWakeReadinessKinds = try backendContractVariants(manifest, "wakeReadiness")

        var beepThreadProjectionKinds: Set<String> = []
        var membershipKinds: Set<String> = []
        var conversationStatusKinds: Set<String> = []
        for example in try backendContractExamples(manifest, "channelState") {
            let payload = try backendContractDictionary(example["payload"], path: "channelState.payload")
            let decoded = try decoder.decode(
                TurboChannelStateResponse.self,
                from: try backendContractPayloadData(payload)
            )
            #expect(decoded.channelId == payload["channelId"] as? String)

            let relationship = try backendContractDictionary(
                payload["beepThreadProjection"],
                path: "channelState.beepThreadProjection"
            )
            beepThreadProjectionKinds.insert(try backendContractString(relationship["kind"], path: "beepThreadProjection.kind"))

            let membership = try backendContractDictionary(payload["membership"], path: "channelState.membership")
            membershipKinds.insert(try backendContractString(membership["kind"], path: "membership.kind"))

            let conversationStatus = try backendContractDictionary(
                payload["conversationStatus"],
                path: "channelState.conversationStatus"
            )
            conversationStatusKinds.insert(try backendContractString(conversationStatus["kind"], path: "conversationStatus.kind"))
        }

        #expect(beepThreadProjectionKinds == expectedBeepThreadProjectionKinds)
        #expect(membershipKinds == expectedMembershipKinds)
        #expect(conversationStatusKinds == expectedConversationStatusKinds)

        var readinessKinds: Set<String> = []
        var audioReadinessKinds: Set<String> = []
        var wakeReadinessKinds: Set<String> = []
        for example in try backendContractExamples(manifest, "channelReadiness") {
            let payload = try backendContractDictionary(example["payload"], path: "channelReadiness.payload")
            let decoded = try decoder.decode(
                TurboChannelReadinessResponse.self,
                from: try backendContractPayloadData(payload)
            )
            #expect(decoded.channelId == payload["channelId"] as? String)

            let readiness = try backendContractDictionary(payload["readiness"], path: "channelReadiness.readiness")
            readinessKinds.insert(try backendContractString(readiness["kind"], path: "readiness.kind"))

            let audioReadiness = try backendContractDictionary(
                payload["audioReadiness"],
                path: "channelReadiness.audioReadiness"
            )
            for side in ["self", "peer"] {
                let sidePayload = try backendContractDictionary(audioReadiness[side], path: "audioReadiness.\(side)")
                audioReadinessKinds.insert(try backendContractString(sidePayload["kind"], path: "audioReadiness.\(side).kind"))
            }

            let wakeReadiness = try backendContractDictionary(
                payload["wakeReadiness"],
                path: "channelReadiness.wakeReadiness"
            )
            for side in ["self", "peer"] {
                let sidePayload = try backendContractDictionary(wakeReadiness[side], path: "wakeReadiness.\(side)")
                wakeReadinessKinds.insert(try backendContractString(sidePayload["kind"], path: "wakeReadiness.\(side).kind"))
            }
        }

        #expect(readinessKinds == expectedReadinessKinds)
        #expect(audioReadinessKinds == expectedAudioReadinessKinds)
        #expect(wakeReadinessKinds == expectedWakeReadinessKinds)

        for example in try backendContractInvalidExamples(manifest) {
            let name = try backendContractString(example["name"], path: "invalidExamples.name")
            let target = try backendContractString(example["target"], path: "\(name).target")
            let payload = try backendContractDictionary(example["payload"], path: "\(name).payload")
            let payloadData = try backendContractPayloadData(payload)
            do {
                switch target {
                case "channelState":
                    _ = try decoder.decode(TurboChannelStateResponse.self, from: payloadData)
                case "channelReadiness":
                    _ = try decoder.decode(TurboChannelReadinessResponse.self, from: payloadData)
                default:
                    throw BackendContractManifestError.missing("unsupported invalid example target \(target)")
                }
                Issue.record("Expected backend contract invalid example \(name) to fail decoding")
            } catch let manifestError as BackendContractManifestError {
                throw manifestError
            } catch {
            }
        }
    }

    @Test func contactSummaryPrefersNestedContractOverLegacyFields() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@peer",
              "displayName": "Peer",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingBeep": false,
              "hasOutgoingBeep": true,
              "requestCount": 2,
              "isActiveConversation": true,
              "badgeStatus": "outgoing-beep",
              "beepThreadProjection": {
                "kind": "incoming",
                "requestCount": 2
              },
              "membership": {
                "kind": "peer-only",
                "peerDeviceConnected": true
              },
              "summaryStatus": {
                "kind": "outgoing-beep"
              }
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)

        #expect(summary.beepThreadProjection == .incoming(requestCount: 2))
        #expect(summary.hasIncomingBeep == true)
        #expect(summary.hasOutgoingBeep == false)
        #expect(summary.requestCount == 2)
        #expect(summary.badge == .outgoingBeep)
        #expect(summary.badgeStatus == "outgoing-beep")
    }

    @Test func channelStatePrefersNestedContractOverLegacyFields() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@peer",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": true,
              "peerJoined": true,
              "peerDeviceConnected": true,
              "hasIncomingBeep": false,
              "hasOutgoingBeep": false,
              "requestCount": 0,
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true,
              "membership": {
                "kind": "self-only"
              },
              "beepThreadProjection": {
                "kind": "none"
              },
              "conversationStatus": {
                "kind": "ready"
              }
            }
            """.utf8
        )

        let channelState = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)

        #expect(channelState.membership == .selfOnly)
        #expect(channelState.selfJoined == true)
        #expect(channelState.peerJoined == false)
        #expect(channelState.peerDeviceConnected == false)
        #expect(channelState.beepThreadProjection == .none)
        #expect(channelState.statusView == .ready)
        #expect(channelState.status == "ready")
    }

    @MainActor
    @Test func transmitStartSignalCompletionAfterReleaseDoesNotEmitStaleSideEffectInvariant() async throws {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        client.enableSentSignalCaptureForTesting()
        client.setSignalSendDelayForTesting(nanoseconds: 100_000_000)
        installSuccessfulBeginTransmitOverride()
        defer { TurboBackendCriticalHTTPClient.beginTransmitOverride = nil }

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }

        viewModel.beginTransmit()
        try await waitForCondition(
            "Apple-gated Direct QUIC handoff request",
            timeoutNanoseconds: 2_000_000_000,
            pollNanoseconds: 20_000_000
        ) {
            pttClient.beginTransmitRequests == [channelUUID]
        }
        viewModel.handleDidBeginTransmitting(channelUUID, source: "test")
        viewModel.isPTTAudioSessionActive = true

        let activationTask = Task { @MainActor in
            await viewModel.completeSystemTransmitActivation(channelUUID: channelUUID)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        viewModel.endTransmit()
        await activationTask.value
        try await waitForCondition(
            "post-send transmit activation cancellation",
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 20_000_000
        ) {
            viewModel.diagnosticsTranscript.contains(
                "Cancelled stale system transmit activation continuation"
            )
        }

        #expect(client.sentSignalsForTesting().filter { $0.type == .transmitStart }.count == 1)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "transmit-start-signal-sent"
            ) == nil
        )
        #expect(viewModel.diagnosticsTranscript.contains("Cancelled stale system transmit activation continuation"))
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.stale_startup_side_effect"
            }
        )
    }

    @Test func mediaRuntimeBudgetsIncomingRelayAudioDiagnostics() {
        let runtime = MediaRuntimeState()
        let contactID = UUID()

        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .detailed
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .detailed
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .suppressedNotice
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .suppressed
        )

        runtime.resetIncomingRelayAudioDiagnostics(for: contactID, detailedReportLimit: 1)

        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .detailed
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .suppressedNotice
        )
    }

    @MainActor
    @Test func incomingAudioChunkDiagnosticsAreBudgeted() async throws {
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
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                )
            )
        )

        for index in 0..<5 {
            viewModel.handleIncomingSignal(
                TurboSignalEnvelope(
                    type: .audioChunk,
                    channelId: "channel-123",
                    fromUserId: "peer-user",
                    fromDeviceId: "peer-device",
                    toUserId: "self-user",
                    toDeviceId: "self-device",
                    payload: AudioChunkPayloadCodec.encode([
                        Data([UInt8(index)]).base64EncodedString()
                    ])
                )
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let detailedEntries = viewModel.diagnostics.entries.filter {
            $0.message == "Audio chunk received"
        }
        let suppressedEntries = viewModel.diagnostics.entries.filter {
            $0.message == "Suppressing repetitive audio chunk diagnostics"
        }

        #expect(detailedEntries.count == 3)
        #expect(suppressedEntries.count == 1)
        #expect(
            detailedEntries.allSatisfy {
                $0.metadata["transportDigest"] != nil
                    && $0.metadata["decodedChunkCount"] != nil
            }
        )
        #expect(suppressedEntries.first?.metadata["detailedReportLimit"] == "3")
    }

    @MainActor
    @Test func packetMetadataDebugOverrideDoesNotExpandLiveIncomingAudioDiagnosticBudget() {
        let previousValue = TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled()
        TurboAudioDiagnosticsDebugOverride.setPacketMetadataEnabled(true)
        defer {
            TurboAudioDiagnosticsDebugOverride.setPacketMetadataEnabled(previousValue)
        }

        let viewModel = PTTViewModel()
        let runtime = MediaRuntimeState()
        let contactID = UUID()

        #expect(TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled())
        #expect(viewModel.incomingAudioDiagnosticDetailedReportLimit() == 3)
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: viewModel.incomingAudioDiagnosticDetailedReportLimit()
            ) == .detailed
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: viewModel.incomingAudioDiagnosticDetailedReportLimit()
            ) == .detailed
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: viewModel.incomingAudioDiagnosticDetailedReportLimit()
            ) == .detailed
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: viewModel.incomingAudioDiagnosticDetailedReportLimit()
            ) == .suppressedNotice
        )
    }

    @MainActor
    @Test func notificationNotNowWithoutBackendRecordsDeclineDiagnostic() async {
        let viewModel = PTTViewModel()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }

        await viewModel.handleBeepNotificationNotNowResponse(
            userInfo: ["event": TurboNotificationCategory.beepEvent, "fromHandle": "@avery", "beepId": "beep-1"]
        )

        #expect(badgeCounts.first == 0)
        #expect(clearNotificationsCallCount == 1)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Cannot decline Beep notification before backend is ready"
            )
        )
    }

    @MainActor
    @Test func staleForegroundBeepNotificationAfterAcceptDoesNotEmitProjectionInvariant() async {
        let viewModel = PTTViewModel()
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
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueConnect(
            contactID: contactID,
            origin: .acceptingIncomingBeep
        )

        await viewModel.refreshBeepStateAfterNotification(
            userInfo: ["event": TurboNotificationCategory.beepEvent, "fromHandle": "@avery", "beepId": "beep-1"],
            reason: "foreground-notification"
        )

        #expect(
            !viewModel.diagnosticsTranscript.contains("beep.foreground_notification_not_projected")
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Ignored stale foreground Beep notification after Beep was already handled"
            )
        )
    }

    @MainActor
    @Test func foregroundBeepNotificationWithoutIncomingBeepStillEmitsProjectionInvariant() async {
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
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID

        await viewModel.refreshBeepStateAfterNotification(
            userInfo: ["event": TurboNotificationCategory.beepEvent, "fromHandle": "@avery", "beepId": "beep-1"],
            reason: "foreground-notification"
        )

        viewModel.reconcileIncomingBeepSurface(
            applicationState: .active,
            allowsSelectedContact: true,
            allowsAlreadySurfacedBeep: true
        )

        #expect(
            viewModel.diagnosticsTranscript.contains("beep.foreground_notification_not_projected")
        )
        #expect(viewModel.activeIncomingBeep?.contactID == contactID)
        #expect(viewModel.activeIncomingBeep?.beepID == "beep-1")
    }

    @MainActor
    @Test func beepSyncPartialRecoveryDoesNotSurfaceAsLatestError() {
        let viewModel = PTTViewModel()

        viewModel.recordBeepSyncPartialRecovery(
            failedRoute: "outgoing",
            error: URLError(.timedOut)
        )

        let entry = viewModel.diagnostics.entries.first {
            $0.message == "Beep sync partially recovered"
        }
        #expect(entry?.level == .notice)
        #expect(entry?.metadata["failedRoute"] == "outgoing")
        #expect(viewModel.diagnostics.latestError == nil)
        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func receiverAudioReadinessPublishEmitsInvariantForBackgroundNotReadyWithoutWakeReason() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: false)
        )

        viewModel.applicationStateOverride = .background
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        await viewModel.publishReceiverAudioReadiness(
            ReceiverAudioReadinessIntent(
                contactID: contactID,
                contactHandle: "@blake",
                backendChannelID: "channel",
                remoteUserID: "peer-user",
                currentUserID: "user-self",
                deviceID: "self-device",
                isReady: false,
                reason: .channelRefresh,
                telemetry: nil
            )
        )

        #expect(viewModel.diagnostics.invariantViolations.contains {
            $0.invariantID == "receiver.background_not_ready_without_wake_reason"
                && $0.metadata["reason"] == ReceiverAudioReadinessReason.channelRefresh.wireValue
        })
    }

    @MainActor
    @Test func mediaRelayPeerUnavailableInvariantIsRecorded() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID

        viewModel.recordMediaRelayPeerUnavailableInvariantIfNeeded(
            error: DirectQuicProbeError.connectionFailed("media relay peer is unavailable"),
            contactID: contactID,
            channelID: "channel-1",
            peerDeviceID: "peer-device",
            operation: "audio-payload"
        )

        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "relay.send_without_live_peer"
                    && $0.metadata["operation"] == "audio-payload"
                    && $0.metadata["peerDeviceId"] == "peer-device"
            }
        )
    }

    @MainActor
    @Test func mediaRelayPeerUnavailableInvariantIgnoresOtherRelayErrors() {
        let viewModel = PTTViewModel()

        viewModel.recordMediaRelayPeerUnavailableInvariantIfNeeded(
            error: DirectQuicProbeError.connectionFailed("media relay is not connected"),
            contactID: UUID(),
            channelID: "channel-1",
            peerDeviceID: "peer-device",
            operation: "audio-payload"
        )

        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "relay.send_without_live_peer"
            }
        )
    }

    @MainActor
    @Test func joinChannelEmitsTransportTraceForHedgedControlCommand() async throws {
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting()
        client.setControlCommandHedgeDelayForTesting(nanoseconds: 1_000_000)

        var traces: [TurboBackendClient.ControlCommandTraceEvent] = []
        client.onControlCommandTrace = { event in
            traces.append(event)
        }
        client.controlCommandWebSocketResponseForTesting = { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return makeJoinResponseData(status: "websocket")
        }
        client.controlCommandHTTPResponseForTesting = { _, _ in
            return makeJoinResponseData(status: "http")
        }

        let response = try await client.joinChannel(channelId: "channel-trace", operationId: "join-op-trace")

        #expect(response.status == "http")
        #expect(
            traces.contains {
                $0.commandKind == "join-channel"
                    && $0.transport == .webSocket
                    && $0.phase == .started
                    && $0.operationId == "join-op-trace"
                    && $0.channelId == "channel-trace"
            }
        )
        #expect(
            traces.contains {
                $0.commandKind == "join-channel"
                    && $0.transport == .http
                    && $0.phase == .hedgeStarted
                    && $0.operationId == "join-op-trace"
                    && $0.channelId == "channel-trace"
            }
        )
        #expect(
            traces.contains {
                $0.commandKind == "join-channel"
                    && $0.transport == .http
                    && $0.phase == .responseReceived
                    && $0.operationId == "join-op-trace"
                    && $0.channelId == "channel-trace"
            }
        )
    }

    @MainActor
    @Test func leaveChannelEmitsTransportTraceForHedgedControlCommand() async throws {
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting()
        client.setControlCommandHedgeDelayForTesting(nanoseconds: 1_000_000)

        var traces: [TurboBackendClient.ControlCommandTraceEvent] = []
        client.onControlCommandTrace = { event in
            traces.append(event)
        }
        client.controlCommandWebSocketResponseForTesting = { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return makeLeaveResponseData(status: "websocket")
        }
        client.controlCommandHTTPResponseForTesting = { _, _ in
            return makeLeaveResponseData(status: "http")
        }

        let response = try await client.leaveChannel(channelId: "channel-trace", operationId: "leave-op-trace")

        #expect(response.status == "http")
        #expect(
            traces.contains {
                $0.commandKind == "leave-channel"
                    && $0.transport == .webSocket
                    && $0.phase == .started
                    && $0.operationId == "leave-op-trace"
                    && $0.channelId == "channel-trace"
            }
        )
        #expect(
            traces.contains {
                $0.commandKind == "leave-channel"
                    && $0.transport == .http
                    && $0.phase == .hedgeStarted
                    && $0.operationId == "leave-op-trace"
                    && $0.channelId == "channel-trace"
            }
        )
        #expect(
            traces.contains {
                $0.commandKind == "leave-channel"
                    && $0.transport == .http
                    && $0.phase == .responseReceived
                    && $0.operationId == "leave-op-trace"
                    && $0.channelId == "channel-trace"
            }
        )
    }

    @Test func devSelfCheckReducerTracksRunningAndLatestReport() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let request = DevSelfCheckRequest(
            startedAt: startedAt,
            hasBackendConfig: true,
            isBackendClientReady: true,
            microphonePermission: .granted,
            selectedTarget: nil
        )
        let report = DevSelfCheckReport(
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            targetHandle: nil,
            steps: [DevSelfCheckStep(.backendConfig, status: .passed, detail: "ok")]
        )

        let started = DevSelfCheckReducer.reduce(
            state: .initial,
            event: .runRequested(request)
        )
        let completed = DevSelfCheckReducer.reduce(
            state: started.state,
            event: .runCompleted(report)
        )

        #expect(started.state.isRunning)
        #expect(started.effects == [.run(request)])
        #expect(completed.state.isRunning == false)
        #expect(completed.state.latestReport == report)
    }

    @Test func devSelfCheckRunnerSkipsFriendStepsWithoutSelection() async {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let request = DevSelfCheckRequest(
            startedAt: startedAt,
            hasBackendConfig: true,
            isBackendClientReady: true,
            microphonePermission: .granted,
            selectedTarget: nil
        )
        let services = DevSelfCheckServices(
            fetchRuntimeConfig: { TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: false) },
            authenticate: { TurboAuthSessionResponse(userId: "user-self", handle: "@self", displayName: "Self") },
            heartbeatPresence: { TurboPresenceHeartbeatResponse(deviceId: "device", userId: "user-self", status: "ok") },
            ensureWebSocketConnected: {},
            waitForWebSocketConnection: {},
            lookupUser: { _ in Issue.record("lookupUser should not run without a selected target"); return TurboUserLookupResponse(userId: "", handle: "", displayName: "") },
            directChannel: { _ in Issue.record("directChannel should not run without a selected target"); return TurboDirectChannelResponse(channelId: "", lowUserId: "", highUserId: "", createdAt: "") },
            channelState: { _ in Issue.record("channelState should not run without a selected target"); return makeChannelState(status: .idle, canTransmit: false) },
            alignmentAction: { _ in .none }
        )

        let outcome = await DevSelfCheckRunner.run(
            request: request,
            services: services
        )

        #expect(outcome.authenticatedUserID == "user-self")
        #expect(outcome.contactUpdate == nil)
        #expect(outcome.channelStateUpdate == nil)
        #expect(outcome.report.isPassing)
        #expect(
            outcome.report.steps.map(\.id)
                == [
                    .backendConfig,
                    .microphonePermission,
                    .runtimeConfig,
                    .authSession,
                    .deviceHeartbeat,
                    .websocket,
                    .friendLookup,
                    .directChannel,
                    .channelState,
                    .sessionAlignment
                ]
        )
        #expect(outcome.report.steps.first(where: { $0.id == .microphonePermission })?.status == .passed)
        #expect(outcome.report.steps.first(where: { $0.id == .websocket })?.status == .skipped)
        #expect(outcome.report.steps.suffix(4).allSatisfy { $0.status == .skipped })
    }

    @Test func selfCheckSummaryPrefersFailingStep() {
        let report = DevSelfCheckReport(
            startedAt: .now,
            completedAt: .now,
            targetHandle: "@blake",
            steps: [
                DevSelfCheckStep(.backendConfig, status: .passed, detail: "ok"),
                DevSelfCheckStep(.channelState, status: .failed, detail: "state failed")
            ]
        )

        #expect(report.isPassing == false)
        #expect(report.summary == "Self-check failed at channel state")
    }

    @Test func selfCheckSummaryUsesTargetOnSuccess() {
        let report = DevSelfCheckReport(
            startedAt: .now,
            completedAt: .now,
            targetHandle: "@avery",
            steps: [
                DevSelfCheckStep(.backendConfig, status: .passed, detail: "ok"),
                DevSelfCheckStep(.sessionAlignment, status: .passed, detail: "aligned")
            ]
        )

        #expect(report.isPassing)
        #expect(report.summary == "Self-check passed for @avery")
    }

    @MainActor
    @Test func diagnosticsExportIncludesStateTimeline() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "idle",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Blake is online"
            ]
        )

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "friendReady",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "connecting",
                "backendSelfJoined": "false",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedConversationStatus": "Blake is ready to connect"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=friendReady")

        #expect(exported.contains("STATE SNAPSHOT"))
        #expect(exported.contains("STATE TIMELINE"))
        #expect(exported.contains("[selected-conversation-sync]"))
        #expect(exported.contains("phase=friendReady"))
        #expect(exported.contains("status=Blake is ready to connect"))
    }

    @MainActor
    @Test func diagnosticsLatestErrorClearsWhenBoundedBufferDropsOldError() {
        let store = DiagnosticsStore()
        store.clear()

        store.record(.pushToTalk, level: .error, message: "PTT init failed")
        #expect(store.latestError?.message == "PTT init failed")

        for index in 0..<200 {
            store.record(.app, level: .info, message: "info-\(index)")
        }

        #expect(store.entries.count == 200)
        #expect(store.latestError == nil)
    }

    @MainActor
    @Test func diagnosticsExportCanIncludePersistedLogTailBeyondEntryLimit() async throws {
        let store = DiagnosticsStore()
        store.clear()

        store.record(
            .media,
            message: "Audio chunk received",
            metadata: ["transportDigest": "first-packet"]
        )
        for index in 0..<240 {
            store.record(.backend, message: "heartbeat-\(index)")
        }

        #expect(store.entries.count == 200)
        #expect(!store.entries.contains { $0.message == "Audio chunk received" })

        try await waitForCondition(
            "persisted diagnostics log contains evicted packet metadata",
            timeoutNanoseconds: 2_000_000_000,
            pollNanoseconds: 20_000_000
        ) {
            guard let path = store.logFilePath,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            return text.contains("Audio chunk received")
                && text.contains("transportDigest=first-packet")
                && text.contains("heartbeat-239")
        }

        let exported = store.exportText(
            includePersistedLogTail: true,
            persistedLogTailMaxBytes: 128_000
        )

        #expect(exported.contains("PERSISTED DIAGNOSTICS TAIL"))
        #expect(exported.contains("Audio chunk received"))
        #expect(exported.contains("transportDigest=first-packet"))
    }

    @MainActor
    @Test func diagnosticsContractGuardRecordsInvariantAndEntry() {
        let store = DiagnosticsStore()
        store.clear()

        let allowed = store.requireContract(
            false,
            kind: .precondition,
            invariantID: "transmit.first_audio_ack_without_expectation",
            scope: .local,
            subsystem: .media,
            message: "first-audio ACK state must be armed before accepting playback ACK",
            metadata: ["channelId": "channel-1"]
        )

        #expect(!allowed)
        #expect(store.invariantViolations.count == 1)
        #expect(store.invariantViolations.first?.invariantID == "transmit.first_audio_ack_without_expectation")
        #expect(store.invariantViolations.first?.metadata["contractKind"] == "precondition")
        #expect(
            store.entries.contains {
                $0.level == .error
                    && $0.subsystem == .media
                    && $0.metadata["invariantID"] == "transmit.first_audio_ack_without_expectation"
            }
        )
    }

    @MainActor
    @Test func diagnosticsContractGuardDoesNotRecordWhenConditionHolds() {
        let store = DiagnosticsStore()
        store.clear()

        let allowed = store.requireContract(
            true,
            kind: .postcondition,
            invariantID: "media.outbound_audio_transport_backpressure_drop",
            scope: .local,
            subsystem: .media,
            message: "sender queue stayed below backpressure limit"
        )

        #expect(allowed)
        #expect(store.invariantViolations.isEmpty)
        #expect(store.entries.isEmpty)
    }

    @MainActor
    @Test func diagnosticsContractSpecRecordsCatalogMetadata() {
        let store = DiagnosticsStore()
        store.clear()
        let contactID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let allowed = store.requireContract(
            false,
            DiagnosticsContracts.Media.firstAudioAckHasExpectation(
                contactID: contactID,
                channelID: "channel-1",
                senderDeviceID: "sender-device",
                receiverDeviceID: "receiver-device",
                transportDigest: "transport-digest",
                ackID: "ack-1",
                source: "websocket"
            ),
            metadata: ["extra": "value"]
        )

        #expect(!allowed)
        #expect(store.invariantViolations.count == 1)
        #expect(
            store.invariantViolations.first?.metadata["contractName"]
                == "media.first_audio_ack_requires_pending_expectation"
        )
        #expect(store.invariantViolations.first?.metadata["contractKind"] == "precondition")
        #expect(store.invariantViolations.first?.metadata["scope"] == "local")
        #expect(store.invariantViolations.first?.metadata["extra"] == "value")
        #expect(
            store.entries.contains {
                $0.level == .error
                    && $0.metadata["contractName"] == "media.first_audio_ack_requires_pending_expectation"
                    && $0.metadata["invariantID"] == "transmit.first_audio_ack_without_expectation"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesOutgoingBeepCallFlapInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        let baseFields: [String: String] = [
            "selectedContact": "@blake",
            "selectedConversationPhase": "outgoingBeep",
            "selectedConversationRelationship": "outgoingBeep(requestCount: 1)",
            "pendingAction": "none",
            "isJoined": "false",
            "isTransmitting": "false",
            "systemSession": "none",
            "backendChannelStatus": "none",
            "backendReadiness": "none",
            "backendSelfJoined": "false",
            "backendPeerJoined": "false",
            "backendPeerDeviceConnected": "false",
            "selectedConversationStatus": "Beep sent",
            "uiRoute": "live",
            "uiCallScreenContact": "@blake",
            "uiCallScreenRequestedExpanded": "true",
            "uiCallScreenMinimized": "false",
            "uiPrimaryActionKind": "connect",
            "uiPrimaryActionLabel": "Beep Again",
            "uiPrimaryActionEnabled": "false",
            "uiSelectedConversationPhase": "outgoingBeep",
            "uiSelectedConversationStatus": "Beep sent"
        ]

        store.captureState(
            reason: "selected-conversation-sync",
            fields: baseFields.merging(["uiCallScreenVisible": "false"]) { _, new in new },
            devicePTTProjection: makeDevicePTTDiagnosticsProjection(fields: baseFields),
            uiProjection: UIProjectionDiagnostics(
                route: "live",
                callScreenVisible: false,
                callScreenContactHandle: "@blake",
                callScreenRequestedExpanded: true,
                callScreenMinimized: false,
                primaryActionKind: "connect",
                primaryActionLabel: "Beep Again",
                primaryActionEnabled: false,
                selectedConversationPhase: "outgoingBeep",
                selectedConversationStatus: "Beep sent"
            )
        )
        store.captureState(
            reason: "ui-projection",
            fields: baseFields.merging(["uiCallScreenVisible": "true"]) { _, new in new },
            devicePTTProjection: makeDevicePTTDiagnosticsProjection(fields: baseFields),
            uiProjection: UIProjectionDiagnostics(
                route: "live",
                callScreenVisible: true,
                callScreenContactHandle: "@blake",
                callScreenRequestedExpanded: true,
                callScreenMinimized: false,
                primaryActionKind: "connect",
                primaryActionLabel: "Beep Again",
                primaryActionEnabled: false,
                selectedConversationPhase: "outgoingBeep",
                selectedConversationStatus: "Beep sent"
            )
        )
        store.captureState(
            reason: "selected-conversation-sync",
            fields: baseFields.merging(["uiCallScreenVisible": "false"]) { _, new in new },
            devicePTTProjection: makeDevicePTTDiagnosticsProjection(fields: baseFields),
            uiProjection: UIProjectionDiagnostics(
                route: "live",
                callScreenVisible: false,
                callScreenContactHandle: "@blake",
                callScreenRequestedExpanded: true,
                callScreenMinimized: false,
                primaryActionKind: "connect",
                primaryActionLabel: "Beep Again",
                primaryActionEnabled: false,
                selectedConversationPhase: "outgoingBeep",
                selectedConversationStatus: "Beep sent"
            )
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=outgoingBeep")

        #expect(exported.contains("[selected.outgoing_beep_call_flap]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.outgoing_beep_call_flap"
            }
        )
        #expect(
            store.latestError?.message
                == "selected route flapped between outgoingBeep and call-visible without a phase change"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesCallVisiblePeerOnlineInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        let fields: [String: String] = [
            "selectedContact": "@blake",
            "selectedConversationPhase": "idle",
            "selectedConversationRelationship": "none",
            "pendingAction": "none",
            "isJoined": "false",
            "isTransmitting": "false",
            "systemSession": "none",
            "backendChannelStatus": "none",
            "backendSelfJoined": "false",
            "backendPeerJoined": "false",
            "backendPeerDeviceConnected": "false",
            "selectedConversationStatus": "Blake is online",
            "uiCallScreenVisible": "true",
            "uiCallScreenContact": "@blake",
            "uiCallScreenRequestedExpanded": "true",
            "uiCallScreenMinimized": "false",
            "uiPrimaryActionKind": "connect",
            "uiPrimaryActionLabel": "Connect",
            "uiPrimaryActionEnabled": "true",
            "uiSelectedConversationPhase": "idle",
            "uiSelectedConversationStatus": "Blake is online"
        ]

        store.captureState(
            reason: "ui-projection",
            fields: fields,
            devicePTTProjection: makeDevicePTTDiagnosticsProjection(fields: fields),
            uiProjection: UIProjectionDiagnostics(
                route: "live",
                callScreenVisible: true,
                callScreenContactHandle: "@blake",
                callScreenRequestedExpanded: true,
                callScreenMinimized: false,
                primaryActionKind: "connect",
                primaryActionLabel: "Connect",
                primaryActionEnabled: true,
                selectedConversationPhase: "idle",
                selectedConversationStatus: "Blake is online"
            )
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=idle")

        #expect(exported.contains("[selected.call_visible_peer_online]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.call_visible_peer_online"
            }
        )
        #expect(
            store.latestError?.message
                == "call screen is visible while selected Conversation projection is still plain online/requestable"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesInvariantViolations() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "ready",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "backendCanTransmit": "false",
                "selectedConversationStatus": "Connected"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=ready")

        #expect(exported.contains("INVARIANT VIOLATIONS"))
        #expect(exported.contains("[selected.ready_without_join]"))
        #expect(exported.contains("[selected.ready_while_backend_cannot_transmit]"))
        #expect(store.invariantViolations.contains { $0.invariantID == "selected.ready_without_join" })
        #expect(store.latestError?.message == "selectedConversationPhase=ready while backendCanTransmit=false")
    }

    @MainActor
    @Test func diagnosticsExportIncludesReceivingWithoutJoinedConversationEvidenceInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "receiving",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "receiving",
                "backendReadiness": "receiving",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "false",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Receiving"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=receiving")

        #expect(exported.contains("[selected.receiving_without_joined_conversation_evidence]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.receiving_without_joined_conversation_evidence"
            }
        )
        #expect(
            store.latestError?.message
                == "selectedConversationPhase=receiving without joined Conversation or Device PTT evidence"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesReceivingWithoutJoinedConversationEvidenceInvariantForJoinedActiveSession() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "receiving",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "receiving",
                "backendReadiness": "receiving",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Receiving"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=receiving")

        #expect(!exported.contains("[selected.receiving_without_joined_conversation_evidence]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.receiving_without_joined_conversation_evidence"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesLiveProjectionAfterMembershipExitInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "transmitting",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "true",
                "systemSession": "none",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Speaking"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=transmitting")

        #expect(exported.contains("[selected.live_projection_after_membership_exit]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.live_projection_after_membership_exit"
            }
        )
        #expect(
            store.latestError?.message
                == "selectedConversationPhase=transmitting after local membership exit"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesLiveProjectionAfterMembershipExitInvariantForJoinedTransmit() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "transmitting",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "true",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "self-transmitting",
                "backendReadiness": "self-transmitting",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedConversationStatus": "Speaking"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=transmitting")

        #expect(!exported.contains("[selected.live_projection_after_membership_exit]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.live_projection_after_membership_exit"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesLiveProjectionAfterLeaseExpiryInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "receiving",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "peer-transmitting",
                "backendReadiness": "peer-transmitting",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "backendActiveTransmitterUserId": "peer-user",
                "backendActiveTransmitId": "transmit-expired",
                "backendActiveTransmitExpiresAt": "2001-01-01T00:00:00Z",
                "backendServerTimestamp": "2001-01-01T00:00:06Z",
                "remoteReceiveActive": "true",
                "selectedConversationStatus": "Receiving"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=receiving")

        #expect(exported.contains("[transmit.live_projection_after_lease_expiry]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "transmit.live_projection_after_lease_expiry"
                    && $0.metadata["backendActiveTransmitId"] == "transmit-expired"
                    && $0.metadata["graceMs"] == "5000"
            }
        )
        #expect(
            store.latestError?.message
                == "selectedConversationPhase remained live after backend transmit lease expiry"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesLiveProjectionAfterLeaseExpiryInvariantWithinGrace() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "receiving",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "peer-transmitting",
                "backendReadiness": "peer-transmitting",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "backendActiveTransmitterUserId": "peer-user",
                "backendActiveTransmitId": "transmit-current",
                "backendActiveTransmitExpiresAt": "2099-01-01T00:00:00Z",
                "remoteReceiveActive": "true",
                "selectedConversationStatus": "Receiving"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=receiving")

        #expect(!exported.contains("[transmit.live_projection_after_lease_expiry]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "transmit.live_projection_after_lease_expiry"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesActiveTransmitWithoutAddressableReceiverInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "transmitting",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "true",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "self-transmitting",
                "backendReadiness": "self-transmitting",
                "backendSelfJoined": "true",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendActiveTransmitterUserId": "self-user",
                "backendActiveTransmitId": "transmit-orphaned",
                "remoteWakeCapabilityKind": "unavailable",
                "selectedConversationStatus": "Speaking"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=transmitting")

        #expect(exported.contains("[channel.active_transmit_without_addressable_receiver]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "channel.active_transmit_without_addressable_receiver"
                    && $0.metadata["backendActiveTransmitId"] == "transmit-orphaned"
                    && $0.metadata["remoteWakeCapabilityKind"] == "unavailable"
            }
        )
        #expect(
            store.latestError?.message
                == "backend active transmit has no joined or wake-addressable receiver"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesActiveTransmitWithoutAddressableReceiverWhenWakeCapable() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "transmitting",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "true",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "self-transmitting",
                "backendReadiness": "self-transmitting",
                "backendSelfJoined": "true",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendActiveTransmitterUserId": "self-user",
                "backendActiveTransmitId": "transmit-wake-targeted",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Speaking"
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "channel.active_transmit_without_addressable_receiver"
            }
        )
    }

    @MainActor
    @Test func diagnosticsTranscriptEmbedsStructuredEnvelope() throws {
        let viewModel = PTTViewModel()

        let envelope = viewModel.diagnosticsEnvelope(
            appVersion: "test-app",
            scenarioName: "structured-diagnostics-test",
            scenarioRunID: "run-1"
        )
        let envelopeJSON = try PTTViewModel.structuredDiagnosticsEnvelopeJSON(envelope)
        let transcript = viewModel.diagnosticsTranscriptText(structuredEnvelopeJSON: envelopeJSON)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticsEnvelope.self, from: Data(envelopeJSON.utf8))

        #expect(transcript.contains("STRUCTURED DIAGNOSTICS"))
        #expect(transcript.contains(envelopeJSON))
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.appVersion == "test-app")
        #expect(decoded.deviceId == envelope.deviceId)
        #expect(!decoded.deviceId.isEmpty)
        #expect(decoded.handle == viewModel.currentDevUserHandle)
        #expect(decoded.scenarioName == "structured-diagnostics-test")
        #expect(decoded.scenarioRunId == "run-1")
        #expect(decoded.projection == envelope.projection)
        #expect(decoded.directQuic == envelope.directQuic)
    }

    @MainActor
    @Test func reducerTransitionReportsAreCapturedInDiagnosticsEnvelope() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )

        let report = try #require(
            viewModel.diagnostics.reducerTransitionReports.first {
                $0.reducerName == "ptt-session"
            }
        )
        let envelope = viewModel.diagnosticsEnvelope(appVersion: "test-app")
        let transcript = viewModel.diagnosticsTranscriptText()

        #expect(report.eventName == "didJoinChannel")
        #expect(report.effectsEmitted.contains { $0.contains("syncJoinedChannel") })
        #expect(report.previousStateSummary.contains("systemSession"))
        #expect(report.previousStateSummary.contains("none"))
        #expect(report.nextStateSummary.contains("systemSession"))
        #expect(report.nextStateSummary.contains("joined"))
        #expect(report.correlationIDs["channelUUID"] == channelUUID.uuidString)
        #expect(report.correlationIDs["contactID"] == contactID.uuidString)
        #expect(envelope.reducerTransitionReports.first == report)
        #expect(transcript.contains("REDUCER TRANSITIONS"))
        #expect(transcript.contains("[ptt-session] [didJoinChannel]"))
    }

    @MainActor
    @Test func reducerEmittedInvariantIsCapturedInDiagnosticsEnvelope() throws {
        let viewModel = PTTViewModel()
        let report = ReducerTransitionReport(
            reducerName: "transmit",
            eventName: "stopCompleted",
            previousStateSummary: "activeTarget: transmit-2",
            nextStateSummary: "activeTarget: transmit-2",
            invariantViolationsEmitted: ["transmit.stale_end_overrides_newer_epoch"],
            correlationIDs: [
                "channelID": "channel-123",
                "transmitID": "transmit-1",
            ]
        )

        viewModel.diagnostics.recordReducerTransition(report)

        let envelope = viewModel.diagnosticsEnvelope(appVersion: "test-app")
        let transcript = viewModel.diagnosticsTranscriptText()
        let violation = try #require(
            envelope.invariantViolations.first {
                $0.invariantID == "transmit.stale_end_overrides_newer_epoch"
            }
        )

        #expect(violation.scope == .local)
        #expect(violation.metadata["reducerName"] == "transmit")
        #expect(violation.metadata["eventName"] == "stopCompleted")
        #expect(violation.metadata["channelID"] == "channel-123")
        #expect(transcript.contains("[transmit.stale_end_overrides_newer_epoch]"))
        #expect(transcript.contains("invariants=transmit.stale_end_overrides_newer_epoch"))
    }

    @MainActor
    @Test func devicePTTProjectionComposesCoordinatorFactsInDiagnosticsEnvelope() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)

        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.receiveExecutionCoordinator.send(
            .remoteActivityDetected(contactID: contactID, source: .transmitStartSignal)
        )

        let devicePTT = viewModel
            .diagnosticsEnvelope(appVersion: "test-app")
            .projection
            .devicePTT

        #expect(devicePTT.selectedContactID == contactID.uuidString)
        #expect(devicePTT.selectedHandle == "@blake")
        #expect(devicePTT.activeChannelID == contactID.uuidString)
        #expect(devicePTT.systemChannelUUID == channelUUID.uuidString)
        #expect(devicePTT.systemActiveContactID == contactID.uuidString)
        #expect(devicePTT.remoteReceiveActive == true)
        #expect(devicePTT.remoteReceiveActivityState?.contains("transmitStartSignal") == true)
    }

    @MainActor
    @Test func devicePTTProjectionDerivesCrossCoordinatorInvariantCandidates() {
        let projection = DevicePTTDiagnosticsProjection(
            selectedContactID: UUID().uuidString,
            selectedHandle: "@blake",
            selectedConversationPhase: "waitingForPeer",
            selectedConversationPhaseDetail: "remoteAudioPrewarm",
            selectedConversationRelationship: "none",
            selectedConversationCanTransmit: false,
            selectedConversationAllowsHoldToTalk: false,
            selectedConversationAutoJoinArmed: false,
            isJoined: true,
            isTransmitting: false,
            activeChannelID: UUID().uuidString,
            systemSession: "active(channelUUID: test, contactID: test, transmission: idle)",
            systemActiveContactID: UUID().uuidString,
            systemChannelUUID: UUID().uuidString,
            mediaState: "connected",
            transmitPhase: "idle",
            transmitActiveContactID: nil,
            transmitPressActive: false,
            transmitExplicitStopRequested: false,
            transmitSystemTransmitting: false,
            incomingWakeActivationState: nil,
            incomingWakeBufferedChunkCount: 0,
            remoteReceiveActive: false,
            remoteTransmitStopObserved: false,
            remoteTransmitStopProjectionGraceActive: false,
            remoteReceiveActivityState: nil,
            receiverAudioReadinessState: nil,
            pendingAction: "none",
            localJoinAttempt: nil,
            localJoinAttemptIssuedCount: 0,
            reconciliationAction: "none",
            hadConnectedDevicePTTContinuity: true,
            controlPlaneReconnectGraceActive: false,
            backendSignalingJoinRecoveryActive: false,
            backendJoinSettling: false,
            backendChannelStatus: "ready",
            backendReadiness: "ready",
            backendSelfJoined: true,
            backendPeerJoined: true,
            backendPeerDeviceConnected: true,
            backendActiveTransmitterUserId: nil,
            backendActiveTransmitId: nil,
            backendActiveTransmitExpiresAt: nil,
            backendServerTimestamp: nil,
            backendCanTransmit: true,
            remoteAudioReadiness: "ready",
            remoteWakeCapabilityKind: "wake-capable"
        )

        let candidate = projection.derivedInvariantCandidates.first {
            $0.invariantID == "selected.backend_ready_missing_remote_audio_signal"
        }

        #expect(candidate?.scope == .backend)
        #expect(candidate?.metadata["mediaState"] == "connected")
        #expect(candidate?.metadata["remoteWakeCapabilityKind"] == "wake-capable")
    }

    @MainActor
    @Test func diagnosticsDoNotFlagReadyWhileBackendSelfTransmitting() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "ptt-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "ready",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active",
                "backendChannelStatus": "self-transmitting",
                "backendReadiness": "self-transmitting",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "backendCanTransmit": "false",
                "selectedConversationStatus": "Connected"
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.ready_while_backend_cannot_transmit"
            }
        )
        #expect(store.latestError == nil)
    }

    @MainActor
    @Test func diagnosticsDoNotFlagReadyWhileLocalTransmitIsStopping() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "ptt-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "ready",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active",
                "transmitPhase": "stopping",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "backendCanTransmit": "false",
                "selectedConversationStatus": "Connected"
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.ready_while_backend_cannot_transmit"
            }
        )
        #expect(store.latestError == nil)
    }

    @MainActor
    @Test func diagnosticsDoNotFlagReadyWhenHoldToTalkIsDisabled() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "backend-signal:redundant-direct-quic-transmit-start",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "ready",
                "selectedConversationPhaseDetail": "readyHoldToTalkDisabled",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active",
                "transmitPhase": "idle",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "false",
                "backendCanTransmit": "false",
                "selectedConversationStatus": "Connected"
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.ready_while_backend_cannot_transmit"
            }
        )
        #expect(store.latestError == nil)
    }

    @MainActor
    @Test func diagnosticsDoNotFlagReadyDuringRemoteTransmitStopProjectionGrace() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "transmit-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "ready",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active",
                "transmitPhase": "idle",
                "remoteTransmitStopObserved": "true",
                "remoteTransmitStopProjectionGraceActive": "true",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "false",
                "backendCanTransmit": "false",
                "remoteAudioReadiness": "wakeCapable",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Connected"
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.ready_while_backend_cannot_transmit"
            }
        )
        #expect(store.latestError == nil)
    }

    @MainActor
    @Test func diagnosticsExportIncludesStaleMembershipFriendReadyWithoutLocalDevicePTTEvidenceInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "friendReady",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-self",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedConversationStatus": "Blake is ready to connect"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=friendReady")

        #expect(exported.contains("[selected.stale_membership_friend_ready_without_local_device_ptt_evidence]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.stale_membership_friend_ready_without_local_device_ptt_evidence"
            }
        )
        #expect(
            store.latestError?.message
                == "backend retained durable channel membership while selectedConversationPhase is friendReady without local Device PTT evidence"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesStaleBackendMembershipWithoutLocalDevicePTTEvidenceInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "idle",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "inactive",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Blake is online"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=idle")

        #expect(exported.contains("[selected.stale_backend_membership_without_local_device_ptt_evidence]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.stale_backend_membership_without_local_device_ptt_evidence"
            }
        )
        #expect(
            store.latestError?.message
                == "backend retained inactive durable channel membership without local Device PTT evidence"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendAbsentPendingLocalActionInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.pendingJoin)",
                "selectedConversationRelationship": "none",
                "pendingAction": "connect(BeepBeep.PendingConnectAction.joiningLocal(contactID: 123))",
                "localJoinAttempt": "contactID:123,channelUUID:456",
                "localJoinAttemptIssuedCount": "2",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "idle",
                "backendReadiness": "inactive",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "pendingAction=joiningLocal")

        #expect(exported.contains("[selected.backend_absent_pending_local_action_without_device_ptt_evidence]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
            }
        )
        #expect(
            store.latestError?.message
                == "backend membership is absent, but the selected Conversation still has a pending local Device PTT action without established Device PTT evidence"
        )
        #expect(
            store.latestError?.metadata["localJoinAttempt"]
                == "contactID:123,channelUUID:456"
        )
        #expect(store.latestError?.metadata["localJoinAttemptIssuedCount"] == "2")
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendAbsentPendingLocalActionInvariantDuringBackendJoinSettling() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.pendingJoin)",
                "selectedConversationRelationship": "none",
                "pendingAction": "connect(BeepBeep.PendingConnectAction.joiningLocal(contactID: 123))",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendJoinSettling": "true",
                "backendChannelStatus": "idle",
                "backendReadiness": "inactive",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendIdleStillConnectingInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.pendingJoin)",
                "selectedConversationRelationship": "none",
                "selectedConversationAutoJoinArmed": "false",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "idle",
                "backendReadiness": "inactive",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_idle_without_local_evidence_still_connecting]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_idle_without_local_evidence_still_connecting"
            }
        )
        #expect(
            store.latestError?.message
                == "backend is idle without local Device PTT evidence, but selected Conversation is still connecting"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendIdleWithLocalDevicePTTEvidenceInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.backendConversationTransition)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "mediaState": "connected",
                "backendChannelStatus": "idle",
                "backendReadiness": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedDevicePTTContinuity": "true",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_idle_with_local_device_ptt_evidence]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_idle_with_local_device_ptt_evidence"
            }
        )
        #expect(
            store.latestError?.message
                == "backend regressed to idle while local Device PTT evidence remained active"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendAbsentWithLocalDevicePTTEvidenceInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.backendConversationTransition)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "backendJoinSettling": "false",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_absent_with_local_device_ptt_evidence]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_absent_with_local_device_ptt_evidence"
            }
        )
        #expect(
            store.latestError?.message
                == "backend dropped durable membership while local Device PTT evidence remained active"
        )
        #expect(store.latestError?.metadata["backendJoinSettling"] == "false")
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendAbsentWithLocalDevicePTTEvidenceDuringBackendJoinSettling() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "ptt-callback:token",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.backendConversationTransition)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "backendJoinSettling": "true",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_absent_with_local_device_ptt_evidence]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_absent_with_local_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendIdleWithLocalDevicePTTEvidenceInvariantWithoutLocalDevicePTTEvidence() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.backendConversationTransition)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "none",
                "mediaState": "idle",
                "backendChannelStatus": "idle",
                "backendReadiness": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedDevicePTTContinuity": "true",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_idle_with_local_device_ptt_evidence]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_idle_with_local_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendIdleWithLocalDevicePTTEvidenceDuringReconnectGrace() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.devicePTTTransition)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "mediaState": "connected",
                "backendChannelStatus": "idle",
                "backendReadiness": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedDevicePTTContinuity": "true",
                "controlPlaneReconnectGraceActive": "true",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_idle_with_local_device_ptt_evidence]"))
        #expect(!exported.contains("[selected.backend_membership_absent_ui_still_joined]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_idle_with_local_device_ptt_evidence"
                    || $0.invariantID == "selected.backend_membership_absent_ui_still_joined"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendAbsentPendingLocalActionInvariantDuringBackendRequest() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.backendConversationTransition)",
                "selectedConversationRelationship": "none",
                "pendingAction": "connect(BeepBeep.PendingConnectAction.requestingBackend(contactID: 123))",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "idle",
                "backendReadiness": "inactive",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportsBackendReadyStaleBackendConnectInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.friendReadyToConnect)",
                "selectedConversationRelationship": "none",
                "pendingAction": "connect(BeepBeep.PendingConnectAction.requestingBackend(contactID: 123))",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendCanTransmit": "true",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_ready_stale_backend_connect]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_ready_stale_backend_connect"
            }
        )
        #expect(
            store.latestError?.message
                == "backend and local Device PTT evidence are ready, but selected Conversation is still blocked by stale backend connect pending action"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendAbsentPendingLeaveInvariantDuringExplicitDisconnect() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-status-refresh",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.disconnecting)",
                "selectedConversationRelationship": "none",
                "pendingAction": "leave(BeepBeep.PendingLeaveAction.explicit(contactID: Optional(123)))",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "none",
                "backendReadiness": "none",
                "backendSelfJoined": "none",
                "backendPeerJoined": "none",
                "backendPeerDeviceConnected": "none",
                "selectedConversationStatus": "Disconnecting..."
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesWaitingForSelfNotConnectableInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "idle",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "backendJoinSettling": "false",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-self",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Blake is online"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=idle")

        #expect(exported.contains("[selected.waiting_for_self_ui_not_connectable]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.waiting_for_self_ui_not_connectable"
            }
        )
        #expect(
            store.latestError?.message
                == "backend says the peer is waiting for self, but selectedConversationPhase is still not connectable"
        )
        #expect(store.latestError?.metadata["backendJoinSettling"] == "false")
    }

    @MainActor
    @Test func diagnosticsDoNotFlagWaitingForSelfDuringLocalJoinConvergence() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "ptt-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "outgoingBeep",
                "selectedConversationRelationship": "outgoingBeep(requestCount: 1)",
                "pendingAction": "connect(BeepBeep.PendingConnectAction.joiningLocal(contactID: 123))",
                "backendJoinSettling": "true",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-self",
                "backendSelfJoined": "false",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedConversationStatus": "Beep sent to Blake"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=outgoingBeep")

        #expect(!exported.contains("[selected.waiting_for_self_ui_not_connectable]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.waiting_for_self_ui_not_connectable"
            }
        )
    }

    @MainActor
    @Test func diagnosticsDoNotFlagPeerJoinedNotConnectableDuringLocalJoinConvergence() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "backend-join:accepted-projection",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "outgoingBeep",
                "selectedConversationRelationship": "outgoingBeep(requestCount: 1)",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "backendSelfJoined": "false",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        _ = store.exportText(snapshot: "selectedConversationPhase=outgoingBeep")

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.peer_joined_ui_not_connectable"
            }
        )
    }

    @MainActor
    @Test func diagnosticsDoNotFlagPeerJoinedNotConnectableDuringPendingBeepRelationship() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "backend-sync:beeps",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "outgoingBeep",
                "selectedConversationRelationship": "outgoingBeep(requestCount: 1)",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "outgoing-beep",
                "backendReadiness": "inactive",
                "backendSelfJoined": "false",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedConversationStatus": "Beep sent"
            ]
        )

        _ = store.exportText(snapshot: "selectedConversationPhase=outgoingBeep")

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.peer_joined_ui_not_connectable"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesWakeCapableReceiverNotConnectableInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "idle",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-self",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Blake is online"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=idle")

        #expect(exported.contains("[selected.wake_capable_receiver_ui_not_connectable]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.wake_capable_receiver_ui_not_connectable"
            }
        )
        #expect(
            store.latestError?.message
                == "backend channel is connectable and receiver wake is available, but selectedConversationPhase is still not connectable"
        )
    }

    @MainActor
    @Test func diagnosticsDoesNotFlagWakeCapableReceiverDuringOutstandingOutgoingBeep() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "receiver-audio-readiness:published",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "outgoingBeep",
                "selectedConversationRelationship": "outgoingBeep(requestCount: 1)",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "false",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Beep sent to @blake"
            ]
        )

        _ = store.exportText(snapshot: "selectedConversationPhase=outgoingBeep")

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.wake_capable_receiver_ui_not_connectable"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesLocalJoinFailedDespiteWakeCapableRecoveryInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "localJoinFailed",
                "selectedConversationPhaseDetail": "localJoinFailed(recoveryMessage: \"Connection interrupted\")",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "hadConnectedDevicePTTContinuity": "true",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "true",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Connection interrupted"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=localJoinFailed")

        #expect(exported.contains("[selected.local_join_failed_despite_wake_capable_recovery]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.local_join_failed_despite_wake_capable_recovery"
            }
        )
        #expect(
            store.latestError?.message
                == "selected Conversation regressed to localJoinFailed while backend still retained wake-capable recovery evidence"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesLocalJoinFailedWakeCapableRecoveryInvariantWithoutContinuity() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-status-refresh",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "localJoinFailed",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "hadConnectedDevicePTTContinuity": "false",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "true",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Connection interrupted"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=localJoinFailed")

        #expect(!exported.contains("[selected.local_join_failed_despite_wake_capable_recovery]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.local_join_failed_despite_wake_capable_recovery"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesJoinedSessionLostWakeCapabilityInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "hadConnectedDevicePTTContinuity": "true",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: test, channelUUID: test)",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteAudioReadiness": "wakeCapable",
                "remoteWakeCapabilityKind": "unavailable",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(exported.contains("[selected.joined_conversation_lost_wake_capability]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.joined_conversation_lost_wake_capability"
            }
        )
        #expect(
            store.latestError?.message
                == "joined Conversation retained wake-capable audio readiness without wake capability"
        )
    }

    @MainActor
    @Test func diagnosticsJoinedConversationLostWakeCapabilityAllowsWakeTokenRevocation() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "hadConnectedDevicePTTContinuity": "true",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: test, channelUUID: test)",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteAudioReadiness": "unknown",
                "remoteWakeCapabilityKind": "unavailable",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.joined_conversation_lost_wake_capability"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendInactiveStillJoinedInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.devicePTTTransition)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "hadConnectedDevicePTTContinuity": "true",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: test, channelUUID: test)",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_inactive_ui_still_joined]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_inactive_ui_still_joined"
            }
        )
        #expect(
            store.invariantViolations.contains {
                $0.message
                    == "backend readiness is inactive, but selectedConversationPhase is still waitingForPeer with joined Device PTT evidence"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendMembershipAbsentStillJoinedInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.backendConversationTransition)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedDevicePTTContinuity": "true",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_membership_absent_ui_still_joined]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_membership_absent_ui_still_joined"
            }
        )
        #expect(
            store.latestError?.message
                == "backend says channel membership is absent, but selectedConversationPhase is still waitingForPeer with joined Device PTT evidence"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendMembershipAbsentInvariantDuringScheduledTeardown() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.devicePTTTransition)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "selectedConversationReconciliationAction": "teardownDevicePTTSession(contactID: 123)",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "none",
                "backendReadiness": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedDevicePTTContinuity": "true",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_membership_absent_ui_still_joined]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_membership_absent_ui_still_joined"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendMembershipAbsentInvariantDuringDisconnectingTeardown() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-effect:teardown-device-ptt",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.disconnecting)",
                "selectedConversationRelationship": "none",
                "pendingAction": "leave(BeepBeep.PendingLeaveAction.reconciledTeardown(contactID: 123))",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "idle",
                "backendReadiness": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedDevicePTTContinuity": "true",
                "selectedConversationStatus": "Disconnecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_membership_absent_ui_still_joined]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_membership_absent_ui_still_joined"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesReconciledTeardownWithoutLocalDevicePTTEvidence() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-status-refresh",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.disconnecting)",
                "selectedConversationRelationship": "incomingBeep(requestCount: 1)",
                "pendingAction": "leave(BeepBeep.PendingLeaveAction.reconciledTeardown(contactID: 123))",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "incoming-beep",
                "backendReadiness": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedDevicePTTContinuity": "true",
                "selectedConversationStatus": "Disconnecting..."
            ]
        )

        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.reconciled_teardown_without_local_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendReadyMissingRemoteAudioSignalInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.remoteAudioPrewarm)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "mediaState": "connected",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Waiting for Blake's audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_ready_missing_remote_audio_signal]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_ready_missing_remote_audio_signal"
            }
        )
        #expect(
            store.latestError?.message
                == "backend says the peer is ready and connected, but selectedConversationPhase is still waitingForPeer on remote audio prewarm"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendReadyMissingRemoteAudioSignalInvariantDuringSignalingRecovery() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "backend-signaling:recovery-scheduled",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.remoteAudioPrewarm)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "backendSignalingJoinRecoveryActive": "true",
                "isJoined": "true",
                "mediaState": "connected",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Waiting for Blake's audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_ready_missing_remote_audio_signal]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_ready_missing_remote_audio_signal"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendReadyMissingRemoteAudioSignalInvariantDuringBackendJoinSettling() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "ptt-policy-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.remoteAudioPrewarm)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "backendJoinSettling": "true",
                "isJoined": "true",
                "mediaState": "connected",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteAudioReadiness": "ready",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Waiting for Blake's audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_ready_missing_remote_audio_signal]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_ready_missing_remote_audio_signal"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendReadyMissingRemoteAudioSignalInvariantUntilWakeCapabilityIsKnown() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.remoteAudioPrewarm)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "mediaState": "connected",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteWakeCapabilityKind": "unavailable",
                "selectedConversationStatus": "Waiting for Blake's audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_ready_missing_remote_audio_signal]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_ready_missing_remote_audio_signal"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendReadyMissingRemoteAudioSignalInvariantWhenRemoteAudioExplicitlyWaits() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "backend-signal:receiver-not-ready",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.remoteAudioPrewarm)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "mediaState": "connected",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteAudioReadiness": "waiting",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Waiting for Blake's audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_ready_missing_remote_audio_signal]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_ready_missing_remote_audio_signal"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesWakeCapableReceiverBlockedOnLocalAudioPrewarmInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.localAudioPrewarm)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "hadConnectedDevicePTTContinuity": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "remoteAudioReadiness": "wakeCapable",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(exported.contains("[selected.wake_capable_receiver_blocked_on_local_audio_prewarm]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.wake_capable_receiver_blocked_on_local_audio_prewarm"
            }
        )
        #expect(
            store.latestError?.message
                == "receiver is wake-capable, but selectedConversationPhase is still waitingForPeer on local audio prewarm"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesWakeReadyDuringBackendJoinSettlingInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-conversation-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "wakeReady",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "backendJoinSettling": "true",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "false",
                "backendCanTransmit": "false",
                "remoteAudioReadiness": "wakeCapable",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Hold to talk to wake Blake"
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=wakeReady")

        #expect(exported.contains("[selected.wake_ready_during_backend_join_settling]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.wake_ready_during_backend_join_settling"
            }
        )
        #expect(
            store.latestError?.message
                == "selectedConversationPhase=wakeReady while backend join is still settling"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesWakeCapableLocalAudioPrewarmInvariantWhenReceiverAudioIsReady() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-status-refresh",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.localAudioPrewarm)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "hadConnectedDevicePTTContinuity": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "remoteAudioReadiness": "ready",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.wake_capable_receiver_blocked_on_local_audio_prewarm]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.wake_capable_receiver_blocked_on_local_audio_prewarm"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesWakeCapableLocalAudioPrewarmInvariantWhenReceiverAudioIsWaiting() {
        let store = DiagnosticsStore()
        store.clear()

        captureDevicePTTDiagnosticsState(store,
            reason: "selected-status-refresh",
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedConversationWaitingReason.localAudioPrewarm)",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "hadConnectedDevicePTTContinuity": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "remoteAudioReadiness": "waiting",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedConversationStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedConversationPhase=waitingForPeer")

        #expect(!exported.contains("[selected.wake_capable_receiver_blocked_on_local_audio_prewarm]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.wake_capable_receiver_blocked_on_local_audio_prewarm"
            }
        )
    }

    @MainActor
    @Test func recoveredWakeCapableLocalAudioPrewarmInvariantDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.diagnostics.clear()

        viewModel.diagnostics.record(
            .invariant,
            level: .error,
            message: "receiver is wake-capable, but selectedConversationPhase is still waitingForPeer on local audio prewarm",
            metadata: [
                "invariantID": "selected.wake_capable_receiver_blocked_on_local_audio_prewarm",
                "remoteAudioReadiness": "wakeCapable",
                "remoteWakeCapabilityKind": "wake-capable",
            ]
        )

        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func recoveredBackendAbsentPendingLeaveInvariantDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.diagnostics.clear()

        viewModel.diagnostics.record(
            .invariant,
            level: .error,
            message: "backend membership is absent, but the selected Conversation still has a pending local Device PTT action without established Device PTT evidence",
            metadata: [
                "invariantID": "selected.backend_absent_pending_local_action_without_device_ptt_evidence",
                "pendingAction": "leave(BeepBeep.PendingLeaveAction.explicit(contactID: Optional(123)))",
            ]
        )

        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func recoveredStaleMembershipFriendReadyInvariantDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.diagnostics.clear()

        viewModel.diagnostics.record(
            .invariant,
            level: .error,
            message: "backend retained durable channel membership while selectedConversationPhase is friendReady without local Device PTT evidence",
            metadata: [
                "invariantID": "selected.stale_membership_friend_ready_without_local_device_ptt_evidence",
                "selectedConversationPhase": "friendReady",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "isJoined": "false",
                "systemSession": "none",
            ]
        )

        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func backendAbsentPendingLocalJoinInvariantSurfacesWhileStillCurrent() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)
        viewModel.syncSelectedConversationProjection()
        viewModel.diagnostics.clear()

        viewModel.diagnostics.record(
            .invariant,
            level: .error,
            message: "backend membership is absent, but the selected Conversation still has a pending local Device PTT action without established Device PTT evidence",
            metadata: [
                "invariantID": "selected.backend_absent_pending_local_action_without_device_ptt_evidence",
                "pendingAction": "connect(BeepBeep.PendingConnectAction.joiningLocal(contactID: 123))",
            ]
        )

        #expect(
            viewModel.topChromeDiagnosticsErrorText
                == "invariant: backend membership is absent, but the selected Conversation still has a pending local Device PTT action without established Device PTT evidence"
        )
    }

    @MainActor
    @Test func diagnosticsStoreAcceptsBackgroundRecordCalls() async {
        let store = DiagnosticsStore()
        store.clear()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    store.record(.app, message: "background-\(index)")
                }
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(store.entries.count == 8)
        #expect(store.entries.allSatisfy { $0.message.hasPrefix("background-") })
    }

    @MainActor
    @Test func diagnosticsSnapshotIncludesMachineReadableContactProjection() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: TurboContactSummaryResponse(
                        userId: "user-blake",
                        handle: "@blake",
                        displayName: "Blake",
                        channelId: "channel-1",
                        isOnline: true,
                        hasIncomingBeep: false,
                        hasOutgoingBeep: false,
                        requestCount: 0,
                        isActiveConversation: false,
                        badgeStatus: "online"
                    )
                )
            ])
        )

        let snapshot = viewModel.diagnosticsSnapshot

        #expect(snapshot.contains("contact[@blake].isOnline=true"))
        #expect(snapshot.contains("contact[@blake].listState=idle"))
        #expect(snapshot.contains("contact[@blake].badgeStatus=online"))
    }

    @MainActor
    @Test func devicePTTDiagnosticsDoNotProjectBackendEngineConversationAsJoined() throws {
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
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(
            contactID: contactID,
            handle: "@blake",
            backendChannelID: "channel-123"
        )

        let devicePTT = viewModel
            .diagnosticsEnvelope(appVersion: "test-app")
            .projection
            .devicePTT

        #expect(viewModel.engineSnapshot.conversation.joinedEvidence != nil)
        #expect(viewModel.pttCoordinator.state.systemSessionState == .none)
        #expect(devicePTT.isJoined == false)
        #expect(devicePTT.activeChannelID == nil)
        #expect(devicePTT.systemSession == "none")
    }
}
