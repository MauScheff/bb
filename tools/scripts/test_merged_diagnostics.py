#!/usr/bin/env python3

import argparse
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import convert_production_replay
import extract_engine_trace
import merged_diagnostics
import reliability_intake
import slo_dashboard


def sample_report(
    *,
    handle: str = "@avery",
    device_id: str = "device-avery",
    uploaded_at: str = "2026-05-14T10:00:00Z",
    structured_diagnostics: dict | None = None,
    snapshot: dict[str, str] | None = None,
    invariant_violations: list[merged_diagnostics.InvariantViolation] | None = None,
    diagnostics: list[tuple[datetime, str]] | None = None,
) -> merged_diagnostics.Report:
    return merged_diagnostics.Report(
        handle=handle,
        device_id=device_id,
        app_version="1.0",
        scenario_name=None,
        scenario_run_id=None,
        uploaded_at=uploaded_at,
        structured_diagnostics=structured_diagnostics,
        snapshot=snapshot
        or {
            "selectedConversationPhase": "ready",
            "selectedConversationStatus": "Ready",
            "selectedContact": "@blake",
            "backendSelfJoined": "true",
            "backendPeerJoined": "true",
            "backendPeerDeviceConnected": "true",
            "backendChannelStatus": "ready",
            "backendReadiness": "ready",
            "isJoined": "true",
            "systemSession": "active(contactID: 123, channelUUID: 456)",
        },
        state_timeline=[],
        invariant_violations=invariant_violations or [],
        backend_invariant_violations=[],
        diagnostics=diagnostics or [],
        wake_events=[],
    )


class MergedDiagnosticsClassificationTests(unittest.TestCase):
    def test_structured_diagnostics_snapshot_includes_transport_projection(self) -> None:
        snapshot = merged_diagnostics.snapshot_from_structured_diagnostics(
            {
                "handle": "@avery",
                "projection": {
                    "selectedConversation": {
                        "selectedHandle": "@blake",
                        "selectedPhase": "ready",
                        "mediaState": "connected",
                        "backendReadiness": "ready",
                    },
                    "isWebSocketConnected": True,
                    "statusMessage": "Ready",
                    "backendStatusMessage": "Direct path active",
                },
                "directQuic": {
                    "transportPathState": "direct",
                    "mediaRelayActive": False,
                    "mediaRelayEnabled": True,
                    "effectiveUpgradeEnabled": True,
                    "isDirectActive": True,
                    "localDeviceID": "device-avery",
                    "peerDeviceID": "device-blake",
                    "attemptID": "attempt-1",
                    "retryReason": None,
                    "probeControllerReady": True,
                },
            }
        )

        self.assertEqual(snapshot["directQuicTransportPath"], "direct")
        self.assertEqual(snapshot["mediaRelayActive"], "false")
        self.assertEqual(snapshot["directQuicEnabled"], "true")
        self.assertEqual(snapshot["directQuicIsActive"], "true")
        self.assertEqual(snapshot["directQuicLocalDeviceId"], "device-avery")
        self.assertEqual(snapshot["directQuicRetryReason"], "none")
        self.assertEqual(snapshot["directQuicProbeControllerReady"], "true")

    def test_report_payload_preserves_engine_trace_for_extraction(self) -> None:
        trace = {
            "schemaVersion": 1,
            "localDeviceID": {"rawValue": "device-avery"},
            "initialState": {},
            "steps": [],
        }
        report = sample_report(
            structured_diagnostics={
                "schemaVersion": 1,
                "engineTrace": trace,
            },
        )

        payload = merged_diagnostics.report_payload(report)

        self.assertEqual(payload["structuredDiagnostics"]["engineTrace"], trace)
        self.assertEqual(extract_engine_trace.find_engine_trace(payload), trace)

    def test_current_violations_keep_latest_recorded_invariants(self) -> None:
        recorded_violation = merged_diagnostics.InvariantViolation(
            subject="@avery",
            invariant_id="selected.backend_ready_ui_not_live",
            scope="local",
            message="backend is ready while selected UI is idle",
            source="structured",
            timestamp=datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc),
        )

        violations, current_violations, historical_violations = merged_diagnostics.classify_violations(
            [sample_report(invariant_violations=[recorded_violation])],
            [],
            [],
        )

        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["selected.backend_ready_ui_not_live"],
        )
        self.assertEqual(
            [violation.invariant_id for violation in current_violations],
            ["selected.backend_ready_ui_not_live"],
        )
        self.assertEqual(historical_violations, [])

    def test_historical_violations_capture_telemetry_only_events(self) -> None:
        historical_event = merged_diagnostics.TelemetryEvent(
            timestamp=datetime(2026, 5, 14, 10, 0, 1, tzinfo=timezone.utc),
            handle="@avery",
            device_id="device-avery",
            session_id="session-1",
            event_name="invariant",
            source="ios",
            severity="error",
            phase="outgoingBeep",
            reason="ui-projection",
            message="selected route flapped between outgoingBeep and call-visible without a phase change",
            channel_id="channel-1",
            peer_handle="@blake",
            invariant_id="selected.outgoing_beep_call_flap",
            metadata_text="",
        )

        violations, current_violations, historical_violations = merged_diagnostics.classify_violations(
            [sample_report()],
            [],
            [historical_event],
        )

        self.assertEqual(
            [violation.invariant_id for violation in current_violations],
            [],
        )
        self.assertEqual(
            [violation.invariant_id for violation in historical_violations],
            ["selected.outgoing_beep_call_flap"],
        )
        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["selected.outgoing_beep_call_flap"],
        )

    def test_strict_merge_fails_on_current_or_historical_violations(self) -> None:
        current_violation = merged_diagnostics.InvariantViolation(
            subject="@avery",
            invariant_id="pair.one_sided_ready_conversation",
            scope="pair",
            message="pair mismatch remains active",
            source="merged",
            timestamp=datetime(2026, 5, 14, 10, 0, 8, tzinfo=timezone.utc),
        )
        historical_violation = merged_diagnostics.InvariantViolation(
            subject="@avery",
            invariant_id="selected.outgoing_beep_call_flap",
            scope="local",
            message="request/call flap recovered",
            source="ios",
            timestamp=datetime(2026, 5, 14, 10, 0, 4, tzinfo=timezone.utc),
        )

        self.assertTrue(
            merged_diagnostics.strict_merge_should_fail([], [historical_violation])
        )
        self.assertTrue(
            merged_diagnostics.strict_merge_should_fail(
                [current_violation],
                [historical_violation],
            )
        )

    def test_duplicate_readiness_publish_without_recovery_boundary_is_violation(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=ready reason=ptt-sync",
            ),
            (
                base.replace(microsecond=470000),
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=ready reason=channel-refresh",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_readiness_publishes(timeline)
        violations = merged_diagnostics.duplicate_readiness_violations(duplicates)

        self.assertEqual(len(duplicates), 1)
        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["receiver.readiness_duplicate_publish_without_recovery_boundary"],
        )
        self.assertEqual(violations[0].metadata["reasons"], "channel-refresh,ptt-sync")

    def test_duplicate_readiness_publish_with_reconnect_boundary_is_allowed(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=ready reason=channel-refresh",
            ),
            (
                base.replace(microsecond=470000),
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=ready reason=websocket-connected",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_readiness_publishes(timeline)
        violations = merged_diagnostics.duplicate_readiness_violations(duplicates)

        self.assertEqual(len(duplicates), 1)
        self.assertEqual(violations, [])

    def test_duplicate_readiness_publish_with_signaling_recovery_boundary_is_allowed(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=ready reason=channel-refresh",
            ),
            (
                base.replace(microsecond=470000),
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=ready reason=backend-signaling-recovery",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_readiness_publishes(timeline)
        violations = merged_diagnostics.duplicate_readiness_violations(duplicates)

        self.assertEqual(len(duplicates), 1)
        self.assertEqual(violations, [])

    def test_duplicate_readiness_publish_cluster_resets_on_opposite_state(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=ready reason=receiver-prewarm-request",
            ),
            (
                base.replace(microsecond=400000),
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=not-ready reason=media-closed",
            ),
            (
                base.replace(microsecond=800000),
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=ready reason=media-preparing",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_readiness_publishes(timeline)
        violations = merged_diagnostics.duplicate_readiness_violations(duplicates)

        self.assertEqual(duplicates, [])
        self.assertEqual(violations, [])

    def test_receiver_ready_from_transitional_media_reason_is_violation(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=ready reason=media-preparing",
            ),
        ]

        violations = merged_diagnostics.receiver_ready_unstable_evidence_violations(timeline)

        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["receiver.readiness_ready_requires_stable_evidence"],
        )
        self.assertEqual(violations[0].metadata["reason"], "media-preparing")

    def test_receiver_not_ready_from_media_closed_is_allowed(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [websocket] Published receiver audio readiness "
                "contactId=contact-1 channelId=channel-1 state=not-ready reason=media-closed",
            ),
        ]

        violations = merged_diagnostics.receiver_ready_unstable_evidence_violations(timeline)

        self.assertEqual(violations, [])

    def test_duplicate_direct_quic_upgrade_request_without_throttle_boundary_is_violation(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [websocket] Direct QUIC upgrade request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=selection-direct-quic-prewarm-channel-refresh requestId=request-1",
            ),
            (
                base.replace(microsecond=2000),
                "[@blake] [diag:info] [websocket] Direct QUIC upgrade request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=selection-direct-quic-prewarm-readiness-channel-refresh requestId=request-2",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_direct_quic_upgrade_requests(timeline)
        violations = merged_diagnostics.duplicate_direct_quic_upgrade_request_violations(duplicates)

        self.assertEqual(len(duplicates), 1)
        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["direct-quic.duplicate_upgrade_request_without_throttle_boundary"],
        )
        self.assertEqual(
            violations[0].metadata["reasons"],
            "selection-direct-quic-prewarm-channel-refresh,"
            "selection-direct-quic-prewarm-readiness-channel-refresh",
        )
        self.assertEqual(violations[0].metadata["requestIds"], "request-1,request-2")

    def test_duplicate_direct_quic_upgrade_request_after_fresh_session_reset_is_allowed(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [websocket] Direct QUIC upgrade request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=selection-direct-quic-prewarm-channel-refresh requestId=request-1",
            ),
            (
                base.replace(microsecond=1000),
                "[@blake] [diag:info] [media] Cleared Direct QUIC fresh-session guards "
                "contactId=contact-1 reason=media-session-closed clearedRetryBackoff=false",
            ),
            (
                base.replace(microsecond=2000),
                "[@blake] [diag:info] [websocket] Direct QUIC upgrade request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=fresh-reconnect requestId=request-2",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_direct_quic_upgrade_requests(timeline)
        violations = merged_diagnostics.duplicate_direct_quic_upgrade_request_violations(duplicates)

        self.assertEqual(duplicates, [])
        self.assertEqual(violations, [])

    def test_direct_quic_upgrade_request_at_throttle_edge_is_allowed(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [websocket] Direct QUIC upgrade request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=selection-direct-quic-prewarm-channel-refresh requestId=request-1",
            ),
            (
                base.replace(second=4, microsecond=950000),
                "[@blake] [diag:info] [websocket] Direct QUIC upgrade request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=selection-direct-quic-prewarm-channel-refresh requestId=request-2",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_direct_quic_upgrade_requests(timeline)
        violations = merged_diagnostics.duplicate_direct_quic_upgrade_request_violations(duplicates)

        self.assertEqual(duplicates, [])
        self.assertEqual(violations, [])

    def test_duplicate_media_relay_receiver_prewarm_request_is_violation(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [media] Media relay receiver prewarm request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=foreground-talk-prewarm-channel-ready requestId=request-1",
            ),
            (
                base.replace(microsecond=2000),
                "[@blake] [diag:info] [media] Media relay receiver prewarm request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=foreground-talk-prewarm-readiness-ready requestId=request-1",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_media_relay_receiver_prewarm_controls(timeline)
        violations = merged_diagnostics.duplicate_media_relay_receiver_prewarm_control_violations(
            duplicates
        )

        self.assertEqual(len(duplicates), 1)
        self.assertEqual(duplicates[0].kind, "request")
        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["media.relay_receiver_prewarm_duplicate_send_without_recovery_boundary"],
        )
        self.assertEqual(violations[0].metadata["requestId"], "request-1")

    def test_duplicate_media_relay_receiver_prewarm_ack_is_violation(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [media] Media relay receiver prewarm ack sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "requestId=request-1",
            ),
            (
                base.replace(microsecond=2000),
                "[@blake] [diag:info] [media] Media relay receiver prewarm ack sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "requestId=request-1",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_media_relay_receiver_prewarm_controls(timeline)
        violations = merged_diagnostics.duplicate_media_relay_receiver_prewarm_control_violations(
            duplicates
        )

        self.assertEqual(len(duplicates), 1)
        self.assertEqual(duplicates[0].kind, "ack")
        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["media.relay_receiver_prewarm_duplicate_send_without_recovery_boundary"],
        )
        self.assertEqual(violations[0].metadata["kind"], "ack")

    def test_media_relay_receiver_prewarm_after_relay_disconnect_is_allowed(self) -> None:
        base = datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc)
        timeline = [
            (
                base,
                "[@blake] [diag:info] [media] Media relay receiver prewarm request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=foreground-talk-prewarm-channel-ready requestId=request-1",
            ),
            (
                base.replace(microsecond=1000),
                "[@blake] [diag:info] [media] Media relay disconnected; returning to WebSocket relay "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1",
            ),
            (
                base.replace(microsecond=2000),
                "[@blake] [diag:info] [media] Media relay receiver prewarm request sent "
                "contactId=contact-1 channelId=channel-1 peerDeviceId=device-1 "
                "reason=fresh-reconnect requestId=request-1",
            ),
        ]

        duplicates = merged_diagnostics.duplicate_media_relay_receiver_prewarm_controls(timeline)
        violations = merged_diagnostics.duplicate_media_relay_receiver_prewarm_control_violations(
            duplicates
        )

        self.assertEqual(duplicates, [])
        self.assertEqual(violations, [])

    def test_mixed_current_pair_and_historical_local_violations_stay_split(self) -> None:
        left_report = sample_report()
        right_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={
                "selectedConversationPhase": "idle",
                "selectedConversationStatus": "Blake is online",
                "selectedContact": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )
        historical_event = merged_diagnostics.TelemetryEvent(
            timestamp=datetime(2026, 5, 14, 10, 0, 1, tzinfo=timezone.utc),
            handle="@avery",
            device_id="device-avery",
            session_id="session-1",
            event_name="invariant",
            source="ios",
            severity="error",
            phase="outgoingBeep",
            reason="ui-projection",
            message="selected route flapped between outgoingBeep and call-visible without a phase change",
            channel_id="channel-1",
            peer_handle="@blake",
            invariant_id="selected.outgoing_beep_call_flap",
            metadata_text="",
        )

        violations, current_violations, historical_violations = merged_diagnostics.classify_violations(
            [left_report, right_report],
            [],
            [historical_event],
        )

        self.assertEqual(
            [violation.invariant_id for violation in current_violations],
            ["pair.one_sided_ready_conversation"],
        )
        self.assertEqual(
            [violation.invariant_id for violation in historical_violations],
            ["selected.outgoing_beep_call_flap"],
        )
        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["pair.one_sided_ready_conversation", "selected.outgoing_beep_call_flap"],
        )

    def test_pair_one_sided_connectable_conversation_catches_connecting_vs_request_split(self) -> None:
        left_report = sample_report(
            snapshot={
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationStatus": "Connecting",
                "selectedContact": "@blake",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "isJoined": "false",
                "systemSession": "none",
            },
        )
        right_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={
                "selectedConversationPhase": "incomingBeep",
                "selectedConversationStatus": "Incoming Beep",
                "selectedContact": "@avery",
                "selectedConversationRelationship": "incomingBeep(requestCount: 1)",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )

        violations = merged_diagnostics.analyze_reports(
            [left_report, right_report],
            include_recorded_violations=False,
        )

        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["pair.one_sided_connectable_conversation"],
        )

    def test_pair_backend_ready_ui_not_live_catches_idle_projection(self) -> None:
        left_report = sample_report()
        right_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={
                "selectedConversationPhase": "idle",
                "selectedConversationStatus": "Blake is online",
                "selectedContact": "@avery",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "isJoined": "false",
                "systemSession": "none",
            },
        )

        violations = merged_diagnostics.analyze_reports(
            [left_report, right_report],
            include_recorded_violations=False,
        )

        self.assertIn(
            "pair.backend_ready_ui_not_live",
            [violation.invariant_id for violation in violations],
        )

    def test_backend_ready_missing_local_device_ptt_evidence_is_selected_violation(self) -> None:
        report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "friendReadyToConnect",
                "selectedConversationStatus": "Connecting...",
                "selectedContact": "@avery",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "localJoinAttempt": "none",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendCanTransmit": "true",
                "isJoined": "false",
                "systemSession": "none",
            },
        )

        violations = merged_diagnostics.analyze_reports(
            [report],
            include_recorded_violations=False,
        )

        self.assertIn(
            "selected.backend_ready_missing_local_device_ptt_evidence",
            [violation.invariant_id for violation in violations],
        )

    def test_backend_ready_missing_local_device_ptt_evidence_ignores_restore_reconciliation(self) -> None:
        report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={
                "selectedConversationPhase": "waitingForPeer",
                "selectedConversationPhaseDetail": "friendReadyToConnect",
                "selectedConversationStatus": "Connecting...",
                "selectedContact": "@avery",
                "selectedConversationRelationship": "none",
                "selectedConversationReconciliationAction": "restoreDevicePTTSession(contactID: 123)",
                "pendingAction": "none",
                "localJoinAttempt": "none",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendCanTransmit": "true",
                "isJoined": "false",
                "systemSession": "none",
            },
        )

        violations = merged_diagnostics.analyze_reports(
            [report],
            include_recorded_violations=False,
        )

        self.assertNotIn(
            "selected.backend_ready_missing_local_device_ptt_evidence",
            [violation.invariant_id for violation in violations],
        )

    def test_joined_conversation_lost_wake_capability_requires_audio_readiness_contradiction(self) -> None:
        base_snapshot = {
            "selectedConversationPhase": "waitingForPeer",
            "selectedConversationStatus": "Connecting...",
            "selectedContact": "@avery",
            "hadConnectedDevicePTTContinuity": "true",
            "backendSelfJoined": "true",
            "backendPeerJoined": "true",
            "backendPeerDeviceConnected": "true",
            "backendChannelStatus": "waiting-for-peer",
            "backendReadiness": "waiting-for-peer",
            "remoteWakeCapabilityKind": "unavailable",
            "isJoined": "true",
            "systemSession": "active(contactID: 123, channelUUID: 456)",
        }

        revoked_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={**base_snapshot, "remoteAudioReadiness": "unknown"},
        )
        contradictory_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={**base_snapshot, "remoteAudioReadiness": "wakeCapable"},
        )

        revoked_violations = merged_diagnostics.analyze_reports(
            [revoked_report],
            include_recorded_violations=False,
        )
        contradictory_violations = merged_diagnostics.analyze_reports(
            [contradictory_report],
            include_recorded_violations=False,
        )

        self.assertNotIn(
            "selected.joined_conversation_lost_wake_capability",
            [violation.invariant_id for violation in revoked_violations],
        )
        self.assertIn(
            "selected.joined_conversation_lost_wake_capability",
            [violation.invariant_id for violation in contradictory_violations],
        )

    def test_remote_audio_timeout_before_sender_stop_is_pair_violation(self) -> None:
        sender_report = sample_report(
            handle="@mau",
            diagnostics=[
                (
                    datetime(2026, 5, 18, 7, 40, 43, 73000, tzinfo=timezone.utc),
                    "[@mau] [diag:info] [ptt] Transmit startup timing "
                    "channelId=channel-1 contactId=contact-mau directQuicActive=true "
                    "stage=system-transmit-ended systemTransmitDurationMs=9593",
                )
            ],
        )
        receiver_report = sample_report(
            handle="@bau",
            device_id="device-bau",
            diagnostics=[
                (
                    datetime(2026, 5, 18, 7, 40, 41, 302000, tzinfo=timezone.utc),
                    "[@bau] [diag:info] [media] Remote audio activity timed out "
                    "contactId=contact-bau phase=drainingAudio",
                )
            ],
        )

        violations = merged_diagnostics.analyze_reports(
            [sender_report, receiver_report],
            include_recorded_violations=False,
        )

        self.assertIn(
            "pair.remote_audio_timeout_before_sender_stop",
            [violation.invariant_id for violation in violations],
        )

    def test_ignored_first_audio_ack_without_prior_completion_is_local_violation(self) -> None:
        report = sample_report(
            diagnostics=[
                (
                    datetime(2026, 5, 18, 7, 40, 43, 326000, tzinfo=timezone.utc),
                    "[@mau] [diag:info] [media] Ignored audio playback ACK without pending expectation "
                    "ackId=ack-1 channelId=channel-1 receiverDeviceId=receiver-1 "
                    "senderDeviceId=sender-1 source=direct-quic-data-channel "
                    "transportDigest=digest-1",
                )
            ],
        )

        violations = merged_diagnostics.analyze_reports(
            [report],
            include_recorded_violations=False,
        )

        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["transmit.first_audio_ack_without_expectation"],
        )

    def test_duplicate_first_audio_ack_after_completion_is_not_violation(self) -> None:
        report = sample_report(
            diagnostics=[
                (
                    datetime(2026, 5, 18, 7, 40, 43, 300000, tzinfo=timezone.utc),
                    "[@mau] [diag:info] [media] First audio playback ACK received "
                    "ackId=ack-1 channelId=channel-1",
                ),
                (
                    datetime(2026, 5, 18, 7, 40, 43, 326000, tzinfo=timezone.utc),
                    "[@mau] [diag:info] [media] Ignored audio playback ACK without pending expectation "
                    "ackId=ack-1 channelId=channel-1 receiverDeviceId=receiver-1 "
                    "senderDeviceId=sender-1 source=direct-quic-data-channel "
                    "transportDigest=digest-1",
                ),
            ],
        )

        violations = merged_diagnostics.analyze_reports(
            [report],
            include_recorded_violations=False,
        )

        self.assertEqual(violations, [])

    def test_outbound_audio_backpressure_drop_is_local_violation(self) -> None:
        report = sample_report(
            diagnostics=[
                (
                    datetime(2026, 5, 18, 7, 40, 43, 277000, tzinfo=timezone.utc),
                    "[@mau] [diag:info] [media] Dropped stale outbound audio transport payload "
                    "droppedPayloadCount=1 maximumPendingPayloads=12 pendingPayloadCount=12 "
                    "reason=outbound-transport-backpressure",
                )
            ],
        )

        violations = merged_diagnostics.analyze_reports(
            [report],
            include_recorded_violations=False,
        )

        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["media.outbound_audio_transport_backpressure_drop"],
        )

    def test_outbound_audio_slow_send_drop_is_local_violation(self) -> None:
        report = sample_report(
            diagnostics=[
                (
                    datetime(2026, 5, 27, 18, 55, 45, 277000, tzinfo=timezone.utc),
                    "[@mau] [diag:info] [media] Dropped stale outbound audio transport payload "
                    "droppedPayloadCount=3 elapsedMilliseconds=9138 maximumPendingPayloads=32 "
                    "pendingPayloadCount=0 reason=outbound-transport-slow-send",
                )
            ],
        )

        violations = merged_diagnostics.analyze_reports(
            [report],
            include_recorded_violations=False,
        )

        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["media.outbound_audio_transport_slow_send_drop"],
        )

    def test_pair_symmetric_friend_ready_without_device_ptt_evidence_catches_durable_membership_split(self) -> None:
        left_report = sample_report(
            snapshot={
                "selectedConversationPhase": "friendReady",
                "selectedConversationStatus": "Blake is ready",
                "selectedContact": "@blake",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )
        right_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={
                "selectedConversationPhase": "friendReady",
                "selectedConversationStatus": "Avery is ready",
                "selectedContact": "@avery",
                "selectedConversationRelationship": "none",
                "pendingAction": "none",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )

        violations = merged_diagnostics.analyze_reports(
            [left_report, right_report],
            include_recorded_violations=False,
        )

        self.assertIn(
            "pair.symmetric_friend_ready_without_device_ptt_evidence",
            [violation.invariant_id for violation in violations],
        )

    def test_pair_pending_outgoing_beep_receiver_not_observed_requires_stale_receiver_evidence(self) -> None:
        sender_report = sample_report(
            uploaded_at="2026-05-14T10:00:10Z",
            snapshot={
                "selectedConversationPhase": "outgoingBeep",
                "selectedConversationStatus": "Beep sent",
                "selectedContact": "@blake",
                "selectedConversationRelationship": "outgoingBeep(requestCount: 1)",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )
        receiver_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            uploaded_at="2026-05-14T10:00:00Z",
            snapshot={
                "selectedConversationPhase": "idle",
                "selectedConversationStatus": "Avery is online",
                "selectedContact": "@avery",
                "selectedConversationRelationship": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )

        violations = merged_diagnostics.analyze_reports(
            [sender_report, receiver_report],
            include_recorded_violations=False,
        )

        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["pair.pending_outgoing_beep_receiver_not_observed"],
        )
        self.assertEqual(
            violations[0].metadata["ageDeltaMs"],
            "10000",
        )
        self.assertEqual(violations[0].metadata["sender"], "@avery")
        self.assertEqual(violations[0].metadata["senderRelationship"], "outgoingBeep(requestCount: 1)")
        self.assertEqual(violations[0].metadata["senderObservedAt"], "2026-05-14T10:00:10Z")

    def test_pair_pending_outgoing_beep_receiver_not_observed_skips_fresh_receiver_gap(self) -> None:
        sender_report = sample_report(
            uploaded_at="2026-05-14T10:00:04Z",
            snapshot={
                "selectedConversationPhase": "outgoingBeep",
                "selectedConversationStatus": "Beep sent",
                "selectedContact": "@blake",
                "selectedConversationRelationship": "outgoingBeep(requestCount: 1)",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )
        receiver_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            uploaded_at="2026-05-14T10:00:00Z",
            snapshot={
                "selectedConversationPhase": "idle",
                "selectedConversationStatus": "Avery is online",
                "selectedContact": "@avery",
                "selectedConversationRelationship": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )

        violations = merged_diagnostics.analyze_reports(
            [sender_report, receiver_report],
            include_recorded_violations=False,
        )

        self.assertNotIn(
            "pair.pending_outgoing_beep_receiver_not_observed",
            [violation.invariant_id for violation in violations],
        )


class ProductionReplayInvariantIDTests(unittest.TestCase):
    def test_invariant_ids_include_current_and_historical_violation_lists(self) -> None:
        payload = {
            "currentViolations": [
                {"invariantId": "selected.call_visible_peer_online"},
            ],
            "historicalViolations": [
                {"invariantId": "selected.outgoing_beep_call_flap"},
            ],
        }

        self.assertEqual(
            convert_production_replay.invariant_ids_from(payload),
            {"selected.call_visible_peer_online", "selected.outgoing_beep_call_flap"},
        )

    def test_mixed_fixture_preserves_current_and_historical_violation_lists(self) -> None:
        fixture_path = Path(__file__).resolve().parent.parent / "fixtures" / "production_replay" / "merged_diagnostics_mixed.json"
        with fixture_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)

        self.assertEqual(
            [violation["invariantId"] for violation in payload["currentViolations"]],
            ["pair.one_sided_ready_conversation"],
        )
        self.assertEqual(
            [violation["invariantId"] for violation in payload["historicalViolations"]],
            ["selected.outgoing_beep_call_flap"],
        )
        self.assertEqual(
            convert_production_replay.invariant_ids_from(payload),
            {"pair.one_sided_ready_conversation", "selected.outgoing_beep_call_flap"},
        )

    def test_pair_matrix_fixture_preserves_multiple_current_pair_violations(self) -> None:
        fixture_path = Path(__file__).resolve().parent.parent / "fixtures" / "production_replay" / "merged_diagnostics_pair_matrix.json"
        with fixture_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)

        self.assertEqual(
            [violation["invariantId"] for violation in payload["currentViolations"]],
            [
                "pair.one_sided_connectable_conversation",
                "pair.backend_ready_ui_not_live",
                "pair.pending_outgoing_beep_receiver_not_observed",
            ],
        )
        self.assertEqual(
            [violation["invariantId"] for violation in payload["historicalViolations"]],
            ["selected.outgoing_beep_call_flap"],
        )
        self.assertEqual(
            convert_production_replay.invariant_ids_from(payload),
            {
                "pair.one_sided_connectable_conversation",
                "pair.backend_ready_ui_not_live",
                "pair.pending_outgoing_beep_receiver_not_observed",
                "selected.outgoing_beep_call_flap",
            },
        )


class DownstreamSplitConsumerTests(unittest.TestCase):
    def test_reliability_intake_split_violations_prefers_split_keys(self) -> None:
        payload = {
            "violations": [{"invariantId": "selected.call_visible_peer_online"}],
            "currentViolations": [{"invariantId": "pair.one_sided_ready_conversation"}],
            "historicalViolations": [{"invariantId": "selected.outgoing_beep_call_flap"}],
        }

        current, historical = reliability_intake.split_violations(payload)

        self.assertEqual(
            [violation["invariantId"] for violation in current],
            ["pair.one_sided_ready_conversation"],
        )
        self.assertEqual(
            [violation["invariantId"] for violation in historical],
            ["selected.outgoing_beep_call_flap"],
        )

    def test_reliability_intake_split_violations_falls_back_to_legacy_list(self) -> None:
        payload = {
            "violations": [{"invariantId": "selected.backend_ready_ui_not_live"}],
        }

        current, historical = reliability_intake.split_violations(payload)

        self.assertEqual(
            [violation["invariantId"] for violation in current],
            ["selected.backend_ready_ui_not_live"],
        )
        self.assertEqual(historical, [])

    def test_slo_dashboard_breaches_only_on_current_violations(self) -> None:
        objective = slo_dashboard.diagnostics_objectives(
            [
                {
                    "_sourcePath": "fixture.json",
                    "currentViolations": [{"invariantId": "pair.one_sided_ready_conversation"}],
                    "historicalViolations": [{"invariantId": "selected.outgoing_beep_call_flap"}],
                }
            ]
        )[0]

        self.assertEqual(objective.status, "breach")
        self.assertEqual(objective.observed, "1")
        self.assertEqual(objective.details["currentCount"], 1)
        self.assertEqual(objective.details["historicalCount"], 1)
        self.assertEqual(
            objective.details["byInvariantId"],
            {"pair.one_sided_ready_conversation": 1},
        )
        self.assertEqual(
            objective.details["historicalByInvariantId"],
            {"selected.outgoing_beep_call_flap": 1},
        )

    def test_slo_dashboard_passes_when_only_historical_violations_exist(self) -> None:
        objective = slo_dashboard.diagnostics_objectives(
            [
                {
                    "_sourcePath": "fixture.json",
                    "currentViolations": [],
                    "historicalViolations": [{"invariantId": "selected.outgoing_beep_call_flap"}],
                }
            ]
        )[0]

        self.assertEqual(objective.status, "pass")
        self.assertEqual(objective.observed, "0")
        self.assertEqual(objective.details["currentCount"], 0)
        self.assertEqual(objective.details["historicalCount"], 1)

    def test_slo_dashboard_counts_multiple_current_pair_violations_from_fixture(self) -> None:
        fixture_path = Path(__file__).resolve().parent.parent / "fixtures" / "production_replay" / "merged_diagnostics_pair_matrix.json"
        with fixture_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)

        objective = slo_dashboard.diagnostics_objectives(
            [{**payload, "_sourcePath": str(fixture_path)}]
        )[0]

        self.assertEqual(objective.status, "breach")
        self.assertEqual(objective.observed, "3")
        self.assertEqual(objective.details["currentCount"], 3)
        self.assertEqual(objective.details["historicalCount"], 1)
        self.assertEqual(
            objective.details["byInvariantId"],
            {
                "pair.backend_ready_ui_not_live": 1,
                "pair.one_sided_connectable_conversation": 1,
                "pair.pending_outgoing_beep_receiver_not_observed": 1,
            },
        )

    def test_reliability_intake_summary_separates_current_and_historical_sections(self) -> None:
        args = argparse.Namespace(
            surface="production",
            incident_id="",
            base_url="https://staging.beepbeep.to",
        )
        payload = {
            "reports": [],
            "telemetrySnapshotReports": [],
            "sourceWarnings": [],
            "violations": [
                {"invariantId": "pair.one_sided_ready_conversation"},
                {"invariantId": "selected.outgoing_beep_call_flap"},
            ],
            "currentViolations": [
                {
                    "invariantId": "pair.one_sided_ready_conversation",
                    "scope": "pair",
                    "source": "merged",
                    "subject": "pair",
                    "timestamp": "2026-05-14T10:00:08Z",
                }
            ],
            "historicalViolations": [
                {
                    "invariantId": "selected.outgoing_beep_call_flap",
                    "scope": "local",
                    "source": "ios",
                    "subject": "@mixedavery",
                    "timestamp": "2026-05-14T10:00:04Z",
                }
            ],
            "telemetryEventCount": 0,
            "telemetryEvents": [],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            summary_path = Path(temp_dir) / "summary.md"
            reliability_intake.write_summary(
                summary_path,
                args=args,
                handles=["@mixedavery", "@mixedblake"],
                devices=[],
                output_dir=Path(temp_dir),
                payload=payload,
                text_result=argparse.Namespace(returncode=0),
                json_result=argparse.Namespace(returncode=0),
                json_error="",
                replay_result=None,
                replay_dir=Path(temp_dir) / "replay",
            )
            summary = summary_path.read_text(encoding="utf-8")

        self.assertIn("- current invariant violations: `1`", summary)
        self.assertIn("- historical invariant violations: `1`", summary)
        self.assertIn("## Current Invariant Violations", summary)
        self.assertIn("## Historical Invariant Violations", summary)


if __name__ == "__main__":
    unittest.main()
