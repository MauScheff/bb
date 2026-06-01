#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import physical_device_boundary_status


class PhysicalDeviceBoundaryStatusTests(unittest.TestCase):
    def test_status_combines_readiness_blocker_and_latest_target_run(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            readiness = root / "readiness.json"
            direct_run = root / "direct-run"
            direct_run.mkdir()
            readiness.write_text(
                json.dumps(
                    {
                        "status": "not-ready",
                        "blockingEvidence": [
                            {
                                "name": "physical-device-boundaries",
                                "status": "fail",
                                "detail": (
                                    "failedCells=[{'name': 'lockscreen-apns-wake'}, "
                                    "{'name': 'direct-quic-media'}]"
                                ),
                                "nextCommands": [
                                    {
                                        "name": "collect-direct-quic-media",
                                        "command": "just physical-device-boundary-collect ...",
                                    },
                                    {
                                        "name": "collect-lockscreen-apns-wake",
                                        "command": "just physical-device-boundary-collect ... --send-wake-apns --wake-channel-id <channel-id> --wake-handle <sender-handle> --target-cell lockscreen-apns-wake",
                                    }
                                ],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (direct_run / "physical-device-boundary-collect.json").write_text(
                json.dumps(
                    {
                        "status": "fail",
                        "ok": False,
                        "targetCell": "direct-quic-media",
                        "generatedAt": "2026-06-01T02:00:00Z",
                        "outputDir": str(direct_run),
                        "operatorBlockers": ["device locked"],
                        "currentDevicePreflight": {
                            "status": "pass",
                            "ok": True,
                            "connectedPhysicalDeviceCount": 1,
                            "blockers": [],
                            "warnings": ["non-connected devices: iPad=disconnected"],
                        },
                        "currentLaunchabilityPreflight": {
                            "status": "fail",
                            "ok": False,
                            "failureReasons": ["locked"],
                            "failedPhysicalDeviceCount": 1,
                        },
                        "launchFailures": [
                            {
                                "device": "iPhone",
                                "udid": "physical-1",
                                "reason": "locked",
                                "message": "locked",
                            }
                        ],
                        "targetCellProof": {
                            "name": "direct-quic-media",
                            "status": "fail",
                            "missingContext": ["Direct QUIC run configuration active"],
                        },
                        "steps": [
                            {"name": "device-list-preflight", "ok": True},
                            {
                                "name": "target-cell-interaction",
                                "skipped": True,
                                "stdout": "large stdout that should not be copied",
                                "stderr": "ERROR: launch failed",
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )

            status = physical_device_boundary_status.build_status(
                str(readiness),
                [str(direct_run)],
                current_devices=[
                    {
                        "name": "iPhone",
                        "udid": "physical-1",
                        "model": "iPhone",
                        "os_version": "26.4",
                        "transport": "localNetwork",
                        "state": "connected",
                    },
                    {
                        "name": "iPad",
                        "udid": "physical-2",
                        "model": "iPad",
                        "os_version": "26.3",
                        "transport": "localNetwork",
                        "state": "disconnected",
                    },
                ],
                lock_states=[
                    {
                        "ok": True,
                        "device": {
                            "name": "iPhone",
                            "udid": "physical-1",
                            "state": "connected",
                        },
                        "passcodeRequired": True,
                        "unlockedSinceBoot": True,
                        "currentLockStateKnown": False,
                        "rawResultKeys": [
                            "deviceIdentifier",
                            "passcodeRequired",
                            "unlockedSinceBoot",
                        ],
                    },
                    {
                        "ok": True,
                        "device": {
                            "name": "iPad",
                            "udid": "physical-2",
                            "state": "disconnected",
                        },
                        "passcodeRequired": True,
                        "unlockedSinceBoot": True,
                        "currentLockStateKnown": False,
                        "rawResultKeys": [
                            "deviceIdentifier",
                            "passcodeRequired",
                            "unlockedSinceBoot",
                        ],
                    },
                ],
                launchability=[
                    {
                        "ok": False,
                        "device": {
                            "name": "iPhone",
                            "udid": "physical-1",
                            "state": "connected",
                        },
                        "reason": "locked",
                        "message": "Unable to launch because the device was not unlocked.",
                        "launchJson": "/tmp/iphone-launch.json",
                    },
                    {
                        "ok": True,
                        "device": {
                            "name": "iPad",
                            "udid": "physical-2",
                            "state": "connected",
                        },
                        "launchJson": "/tmp/ipad-launch.json",
                    },
                ],
            )

        self.assertEqual("not-ready", status["status"])
        self.assertEqual(["lockscreen-apns-wake", "direct-quic-media"], status["missingCells"])
        self.assertEqual("direct-quic-media", status["latestRuns"][0]["targetCell"])
        self.assertEqual("locked", status["actionableCells"]["direct-quic-media"]["launchFailures"][0]["reason"])
        self.assertIn(
            "Unlock this device",
            status["actionableCells"]["direct-quic-media"]["launchFailures"][0][
                "remediation"
            ],
        )
        self.assertEqual(
            "pass",
            status["actionableCells"]["direct-quic-media"]["currentDevicePreflight"]["status"],
        )
        self.assertEqual(
            "fail",
            status["actionableCells"]["direct-quic-media"]["currentLaunchabilityPreflight"]["status"],
        )
        self.assertEqual(
            "target-cell-interaction",
            status["actionableCells"]["direct-quic-media"]["steps"][1]["name"],
        )
        step = status["actionableCells"]["direct-quic-media"]["steps"][1]
        self.assertNotIn("stdout", step)
        self.assertNotIn("stderr", step)
        self.assertEqual(len("large stdout that should not be copied"), step["outputSummary"]["stdoutBytes"])
        self.assertIn("ERROR: launch failed", step["outputSummary"]["diagnosticLines"])
        self.assertEqual("collect-direct-quic-media", status["nextCommands"][0]["name"])
        self.assertEqual("resolve-launch-failure", status["priorityActions"][0]["kind"])
        self.assertEqual("direct-quic-media", status["priorityActions"][0]["cell"])
        self.assertEqual("iPhone", status["priorityActions"][0]["device"])
        self.assertIn("Unlock this device", status["priorityActions"][0]["remediation"])
        self.assertEqual(
            "just device-launch-connected-json",
            status["priorityActions"][0]["verificationCommand"],
        )
        self.assertEqual(
            "/tmp/turbo-device-launch-connected-current.json",
            status["priorityActions"][0]["verificationArtifact"],
        )
        self.assertEqual("locked", status["priorityActions"][0]["currentLaunchabilityProbe"])
        self.assertEqual("collect-missing-cell", status["priorityActions"][1]["kind"])
        self.assertEqual("lockscreen-apns-wake", status["priorityActions"][1]["cell"])
        self.assertIn("wake-channel-id", status["priorityActions"][1]["requirements"])
        self.assertIsNone(status["missingCellPlans"]["lockscreen-apns-wake"]["latestRun"])
        lockscreen_requirements = [
            requirement["name"]
            for requirement in status["missingCellPlans"]["lockscreen-apns-wake"][
                "operatorRequirements"
            ]
        ]
        self.assertIn("wake-channel-id", lockscreen_requirements)
        self.assertIn("wake-sender-handle", lockscreen_requirements)
        self.assertIn(
            "--send-wake-apns",
            status["missingCellPlans"]["lockscreen-apns-wake"]["nextCommand"]["command"],
        )
        self.assertEqual(
            "direct-quic-media",
            status["missingCellPlans"]["direct-quic-media"]["latestRun"]["targetCell"],
        )
        self.assertEqual("pass", status["currentDevicePreflight"]["status"])
        self.assertEqual(1, status["currentDevicePreflight"]["connectedPhysicalDeviceCount"])
        self.assertFalse(status["currentDevicePreflight"]["commandReady"])
        self.assertEqual("partial", status["currentDevicePreflight"]["commandReadinessStatus"])
        self.assertIn("iPad=disconnected", status["currentDevicePreflight"]["warnings"][0])
        self.assertEqual("pass", status["currentLockStateProbe"]["status"])
        self.assertTrue(status["currentLockStateProbe"]["advisoryOnly"])
        self.assertEqual(2, status["currentLockStateProbe"]["reachablePhysicalDeviceCount"])
        self.assertEqual(0, status["currentLockStateProbe"]["currentLockStateKnownCount"])
        self.assertIn(
            "launch diagnostics",
            status["currentLockStateProbe"]["operatorNote"],
        )
        self.assertEqual(
            "pass",
            status["missingCellPlans"]["direct-quic-media"]["currentLockStateProbe"]["status"],
        )
        self.assertEqual("fail", status["currentLaunchabilityProbe"]["status"])
        self.assertEqual(["locked"], status["currentLaunchabilityProbe"]["failureReasons"])
        self.assertEqual(1, status["currentLaunchabilityProbe"]["launchablePhysicalDeviceCount"])

    def test_ready_readiness_has_no_missing_cells(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            readiness = root / "readiness.json"
            readiness.write_text(
                json.dumps({"status": "ready", "blockingEvidence": []}),
                encoding="utf-8",
            )

            status = physical_device_boundary_status.build_status(
                str(readiness),
                [],
                current_devices=[
                    {"name": "iPhone", "udid": "physical-1", "state": "connected"},
                    {"name": "iPad", "udid": "physical-2", "state": "connected"},
                ],
                lock_states=[
                    {"ok": True, "device": {"name": "iPhone", "udid": "physical-1"}},
                    {"ok": True, "device": {"name": "iPad", "udid": "physical-2"}},
                ],
                launchability=[
                    {"ok": True, "device": {"name": "iPhone", "udid": "physical-1"}},
                    {"ok": True, "device": {"name": "iPad", "udid": "physical-2"}},
                ],
            )

        self.assertTrue(status["ok"])
        self.assertEqual("ready", status["status"])
        self.assertEqual([], status["missingCells"])
        self.assertTrue(status["currentDevicePreflight"]["ok"])
        self.assertTrue(status["currentLockStateProbe"]["ok"])
        self.assertTrue(status["currentLaunchabilityProbe"]["ok"])

    def test_status_prefers_structured_finalize_failed_cells_over_detail_text(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            readiness = root / "readiness.json"
            readiness.write_text(
                json.dumps(
                    {
                        "status": "not-ready",
                        "blockingEvidence": [
                            {
                                "name": "physical-device-boundaries",
                                    "status": "fail",
                                    "detail": "legacy detail mentions only direct-quic-media",
                                    "physicalFinalizeSummary": {
                                        "failedCells": [
                                        {
                                            "name": "foreground-ptt-audio",
                                            "reason": "missing foreground transmit",
                                        },
                                        {
                                            "name": "fallback-relay-audio",
                                            "reason": "missing fallback playback",
                                        },
                                    ]
                                },
                                "nextCommands": [],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            status = physical_device_boundary_status.build_status(
                str(readiness),
                [],
                current_devices=[],
                lock_states=[],
                launchability=[],
            )

        self.assertEqual(["foreground-ptt-audio", "fallback-relay-audio"], status["missingCells"])
        self.assertEqual(
            ["foreground-ptt-audio", "fallback-relay-audio"],
            list(status["missingCellPlans"].keys()),
        )
        self.assertEqual(
            "missing foreground transmit",
            status["missingCellPlans"]["foreground-ptt-audio"]["finalizeFailure"]["reason"],
        )
        self.assertEqual(
            "missing fallback playback",
            next(
                action
                for action in status["priorityActions"]
                if action.get("cell") == "fallback-relay-audio"
            )["finalizeFailure"]["reason"],
        )

    def test_status_exposes_finalize_summary_and_evidence_window_at_top_level(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            readiness = root / "readiness.json"
            readiness.write_text(
                json.dumps(
                    {
                        "status": "not-ready",
                        "blockingEvidence": [
                            {
                                "name": "physical-device-boundaries",
                                "status": "fail",
                                "physicalFinalizeSummary": {
                                    "artifact": "/tmp/turbo-physical-device-boundary-finalize.json",
                                    "status": "fail",
                                    "ok": False,
                                    "resolvedManifests": [
                                        "/tmp/turbo-physical-direct-quic-run-current/physical-device-boundary-manifest.json"
                                    ],
                                    "skippedMissingInputs": [
                                        "/tmp/turbo-physical-fallback-relay-run"
                                    ],
                                    "passedCells": [
                                        {"name": "direct-quic-media", "status": "pass"}
                                    ],
                                    "failedCells": [
                                        {
                                            "name": "foreground-ptt-audio",
                                            "reason": "missing foreground transmit",
                                        }
                                    ],
                                    "internalOnly": "do not expose",
                                },
                                "physicalEvidenceWindow": {
                                    "manifestEvidenceSince": "2026-06-01T00:00:00Z",
                                    "sourceEvidenceWindows": [
                                        {
                                            "manifest": "/tmp/turbo-physical-direct-quic-run-current/physical-device-boundary-manifest.json",
                                            "evidenceSince": "2026-06-01T00:00:00Z",
                                        }
                                    ],
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            status = physical_device_boundary_status.build_status(
                str(readiness),
                [],
                current_devices=[],
                lock_states=[],
                launchability=[],
            )

        finalize_summary = status["physicalFinalizeSummary"]
        self.assertEqual("fail", finalize_summary["status"])
        self.assertEqual(
            ["/tmp/turbo-physical-fallback-relay-run"],
            finalize_summary["skippedMissingInputs"],
        )
        self.assertEqual(
            "/tmp/turbo-physical-direct-quic-run-current/physical-device-boundary-manifest.json",
            finalize_summary["resolvedManifests"][0],
        )
        self.assertEqual("foreground-ptt-audio", finalize_summary["failedCells"][0]["name"])
        self.assertNotIn("internalOnly", finalize_summary)
        self.assertEqual(
            "2026-06-01T00:00:00Z",
            status["physicalEvidenceWindow"]["manifestEvidenceSince"],
        )

    def test_status_backfills_launch_failures_from_old_summary_steps(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            run = root / "direct-run"
            run.mkdir()
            (run / "physical-device-boundary-collect.json").write_text(
                json.dumps(
                    {
                        "status": "fail",
                        "targetCell": "direct-quic-media",
                        "steps": [
                            {
                                "name": "device-launch-profile",
                                "stderr": (
                                    "== iPhone (physical-1) ==\n"
                                    "BSErrorCodeDescription = Locked\n"
                                ),
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            summary = physical_device_boundary_status.read_run_summary(str(run))

        self.assertIsNotNone(summary)
        assert summary is not None
        self.assertEqual("locked", summary["launchFailures"][0]["reason"])
        self.assertEqual("physical-1", summary["launchFailures"][0]["udid"])
        self.assertIn("Unlock this device", summary["launchFailures"][0]["remediation"])

    def test_status_promotes_step_launch_failure_over_summary_only_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            run = root / "direct-run"
            run.mkdir()
            (run / "physical-device-boundary-collect.json").write_text(
                json.dumps(
                    {
                        "status": "fail",
                        "targetCell": "direct-quic-media",
                        "launchFailures": [
                            {
                                "device": "iPad",
                                "udid": "physical-2",
                                "reason": "device-command-failed",
                                "message": "run-connected exited 1 for this device",
                            }
                        ],
                        "steps": [
                            {
                                "name": "device-launch-profile",
                                "stderr": (
                                    "== iPad (physical-2) ==\n"
                                    "ERROR: The device disconnected immediately after connecting.\n"
                                    "run-connected failed for device(s): iPad (physical-2) exit=1\n"
                                ),
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            summary = physical_device_boundary_status.read_run_summary(str(run))

        self.assertIsNotNone(summary)
        assert summary is not None
        self.assertEqual("device-disconnected", summary["launchFailures"][0]["reason"])
        self.assertIn("Reconnect this device", summary["launchFailures"][0]["remediation"])

    def test_launch_failure_remediation_preserves_existing_text(self) -> None:
        failure = physical_device_boundary_status.enrich_launch_failure(
            {
                "device": "iPad",
                "udid": "physical-2",
                "reason": "device-disconnected",
                "message": "disconnected",
                "remediation": "custom remediation",
            }
        )

        self.assertEqual("custom remediation", failure["remediation"])

    def test_launch_failure_remediation_handles_coredevice_unavailable(self) -> None:
        failure = physical_device_boundary_status.enrich_launch_failure(
            {
                "device": "iPhone",
                "udid": "physical-1",
                "reason": "device-unavailable",
                "message": "CoreDeviceService was unable to locate a device",
            }
        )

        self.assertIn("Make this device available", failure["remediation"])

    def test_physical_device_preflight_reports_unknown_when_snapshot_missing(self) -> None:
        preflight = physical_device_boundary_status.physical_device_preflight(
            None,
            error="devicectl unavailable",
        )

        self.assertEqual("unknown", preflight["status"])
        self.assertFalse(preflight["ok"])
        self.assertIn("devicectl unavailable", preflight["error"])

    def test_physical_device_preflight_warns_on_stale_disconnected_tunnel_state(self) -> None:
        preflight = physical_device_boundary_status.physical_device_preflight(
            [
                {"name": "iPhone", "udid": "physical-1", "state": "connected"},
                {"name": "iPad", "udid": "physical-2", "state": "disconnected"},
            ]
        )

        self.assertEqual("pass", preflight["status"])
        self.assertEqual(2, preflight["pairedPhysicalDeviceCount"])
        self.assertEqual(1, preflight["connectedPhysicalDeviceCount"])
        self.assertFalse(preflight["commandReady"])
        self.assertEqual("partial", preflight["commandReadinessStatus"])
        self.assertEqual([], preflight["blockers"])
        self.assertIn("iPad=disconnected", preflight["warnings"][0])

    def test_physical_device_preflight_reports_no_command_ready_devices(self) -> None:
        preflight = physical_device_boundary_status.physical_device_preflight(
            [
                {"name": "iPhone", "udid": "physical-1", "state": "unavailable"},
                {"name": "iPad", "udid": "physical-2", "state": "disconnected"},
            ]
        )

        self.assertEqual("pass", preflight["status"])
        self.assertFalse(preflight["commandReady"])
        self.assertEqual("none", preflight["commandReadinessStatus"])
        self.assertEqual(0, preflight["connectedPhysicalDeviceCount"])
        self.assertIn("iPhone=unavailable", preflight["warnings"][0])

    def test_advisory_lock_state_probe_reports_reachability_without_claiming_unlock(self) -> None:
        probe = physical_device_boundary_status.advisory_lock_state_probe(
            [
                {
                    "ok": True,
                    "device": {"name": "iPhone", "udid": "physical-1", "state": "connected"},
                    "passcodeRequired": True,
                    "unlockedSinceBoot": True,
                    "currentLockStateKnown": False,
                    "rawResultKeys": [
                        "deviceIdentifier",
                        "passcodeRequired",
                        "unlockedSinceBoot",
                    ],
                },
                {
                    "ok": False,
                    "device": {"name": "iPad", "udid": "physical-2", "state": "disconnected"},
                    "error": "device unavailable",
                },
            ]
        )

        self.assertEqual("partial", probe["status"])
        self.assertFalse(probe["ok"])
        self.assertTrue(probe["advisoryOnly"])
        self.assertEqual(1, probe["reachablePhysicalDeviceCount"])
        self.assertEqual(1, probe["failedPhysicalDeviceCount"])
        self.assertEqual(0, probe["currentLockStateKnownCount"])
        self.assertIn("advisory", probe["operatorNote"])
        self.assertEqual("device unavailable", probe["devices"][1]["error"])

    def test_launchability_probe_reports_locked_devices_from_snapshot(self) -> None:
        probe = physical_device_boundary_status.launchability_probe(
            [
                {
                    "ok": False,
                    "device": {"name": "iPhone", "udid": "physical-1", "state": "connected"},
                    "reason": "locked",
                    "message": "Unable to launch because the device was locked.",
                    "launchJson": "/tmp/iphone-launch.json",
                },
                {
                    "ok": True,
                    "device": {"name": "iPad", "udid": "physical-2", "state": "connected"},
                    "launchJson": "/tmp/ipad-launch.json",
                },
            ]
        )

        self.assertEqual("fail", probe["status"])
        self.assertFalse(probe["ok"])
        self.assertEqual(1, probe["launchablePhysicalDeviceCount"])
        self.assertEqual(1, probe["failedPhysicalDeviceCount"])
        self.assertEqual(["locked"], probe["failureReasons"])
        self.assertEqual("locked", probe["devices"][0]["reason"])
        self.assertIn("without rebuilding", probe["operatorNote"])

    def test_priority_actions_report_preflight_blockers_first(self) -> None:
        actions = physical_device_boundary_status.priority_actions(
            {},
            {},
            {"blockers": ["fewer than two paired physical iOS devices are visible"]},
        )

        self.assertEqual("resolve-device-preflight", actions[0]["kind"])
        self.assertIn("fewer than two paired", actions[0]["summary"])

    def test_priority_actions_mark_stale_disconnect_when_lock_state_probe_reaches_device(self) -> None:
        actions = physical_device_boundary_status.priority_actions(
            {
                "direct-quic-media": {
                    "launchFailures": [
                        {
                            "device": "iPad",
                            "udid": "physical-2",
                            "reason": "device-disconnected",
                            "remediation": "old remediation",
                        }
                    ]
                }
            },
            {},
            {"blockers": []},
            {
                "devices": [
                    {
                        "name": "iPad",
                        "udid": "physical-2",
                        "ok": True,
                    }
                ]
            },
        )

        self.assertEqual("resolve-launch-failure", actions[0]["kind"])
        self.assertEqual("reachable", actions[0]["currentLockStateProbe"])
        self.assertIn("may be stale", actions[0]["remediation"])

    def test_priority_actions_mark_stale_target_launch_failure_when_current_probe_differs(self) -> None:
        actions = physical_device_boundary_status.priority_actions(
            {
                "direct-quic-media": {
                    "launchFailures": [
                        {
                            "device": "iPhone",
                            "udid": "physical-1",
                            "reason": "locked",
                            "remediation": "old locked remediation",
                        }
                    ]
                }
            },
            {},
            {"blockers": []},
            None,
            {
                "devices": [
                    {
                        "name": "iPhone",
                        "udid": "physical-1",
                        "ok": False,
                        "reason": "device-command-failed",
                    }
                ],
            },
        )

        self.assertEqual("resolve-launch-failure", actions[0]["kind"])
        self.assertTrue(actions[0]["currentLaunchabilityMismatch"])
        self.assertEqual("device-command-failed", actions[0]["currentLaunchabilityProbe"])
        self.assertIn("latest launchability probe", actions[0]["remediation"])

    def test_priority_actions_include_current_launchability_failure_without_target_run(self) -> None:
        actions = physical_device_boundary_status.priority_actions(
            {},
            {},
            {"blockers": []},
            {
                "devices": [
                    {
                        "name": "iPhone",
                        "udid": "physical-1",
                        "ok": True,
                    }
                ]
            },
            {
                "artifact": "/tmp/launchability.json",
                "devices": [
                    {
                        "name": "iPhone",
                        "udid": "physical-1",
                        "ok": False,
                        "reason": "locked",
                        "message": "device locked",
                    }
                ],
            },
        )

        self.assertEqual("resolve-current-launchability-failure", actions[0]["kind"])
        self.assertIsNone(actions[0]["cell"])
        self.assertEqual("iPhone", actions[0]["device"])
        self.assertEqual("locked", actions[0]["reason"])
        self.assertEqual("locked", actions[0]["currentLaunchabilityProbe"])
        self.assertEqual("reachable", actions[0]["currentLockStateProbe"])
        self.assertEqual("/tmp/launchability.json", actions[0]["verificationArtifact"])
        self.assertIn("Unlock this device", actions[0]["remediation"])

    def test_priority_actions_deduplicate_current_launchability_failure_already_seen_in_target_run(self) -> None:
        actions = physical_device_boundary_status.priority_actions(
            {
                "direct-quic-media": {
                    "launchFailures": [
                        {
                            "device": "iPhone",
                            "udid": "physical-1",
                            "reason": "locked",
                        }
                    ]
                }
            },
            {},
            {"blockers": []},
            None,
            {
                "devices": [
                    {
                        "name": "iPhone",
                        "udid": "physical-1",
                        "ok": False,
                        "reason": "locked",
                    }
                ],
            },
        )

        self.assertEqual(1, len(actions))
        self.assertEqual("resolve-launch-failure", actions[0]["kind"])

    def test_priority_actions_include_missing_anchors_for_failed_rerun_cell(self) -> None:
        actions = physical_device_boundary_status.priority_actions(
            {
                "lockscreen-apns-wake": {
                    "launchFailures": [],
                    "targetCellProof": {
                        "missingEvidence": ["incoming push received on locked/background receiver"],
                        "missingContext": ["receiver entered background or locked"],
                    },
                }
            },
            {
                "lockscreen-apns-wake": {
                    "operatorRequirements": [
                        {"name": "receiver-background-or-locked"},
                        {"name": "wake-channel-id"},
                    ],
                    "nextCommand": {"command": "just physical-device-boundary-collect ..."},
                    "finalizeFailure": {
                        "name": "lockscreen-apns-wake",
                        "reason": "missing incoming push",
                    },
                    "latestRun": {
                        "targetCell": "lockscreen-apns-wake",
                        "targetCellProof": {
                            "missingEvidence": ["incoming push received on locked/background receiver"],
                            "missingContext": ["receiver entered background or locked"],
                        },
                    },
                }
            },
            {"blockers": []},
        )

        self.assertEqual("rerun-missing-cell", actions[0]["kind"])
        self.assertIn("receiver-background-or-locked", actions[0]["requirements"])
        self.assertIn(
            "ptt-apns-print-only",
            actions[0]["wakeTargetPreflightCommand"]["command"],
        )
        self.assertEqual(
            ["incoming push received on locked/background receiver"],
            actions[0]["missingEvidence"],
        )
        self.assertEqual(["receiver entered background or locked"], actions[0]["missingContext"])
        self.assertEqual("missing incoming push", actions[0]["finalizeFailure"]["reason"])

    def test_run_summary_carries_apns_credential_preflight(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            run = root / "wake-run"
            run.mkdir()
            (run / "physical-device-boundary-collect.json").write_text(
                json.dumps(
                    {
                        "status": "fail",
                        "targetCell": "lockscreen-apns-wake",
                        "apnsCredentialPreflight": {
                            "status": "pass",
                            "ok": True,
                            "missing": [],
                        },
                        "wakeApnsSent": False,
                    }
                ),
                encoding="utf-8",
            )

            summary = physical_device_boundary_status.read_run_summary(str(run))

        self.assertIsNotNone(summary)
        assert summary is not None
        self.assertEqual("pass", summary["apnsCredentialPreflight"]["status"])
        self.assertFalse(summary["wakeApnsSent"])

    def test_run_summary_carries_structured_send_wake_apns_result(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            run = root / "wake-run"
            run.mkdir()
            (run / "physical-device-boundary-collect.json").write_text(
                json.dumps(
                    {
                        "status": "fail",
                        "targetCell": "lockscreen-apns-wake",
                        "wakeApnsSent": False,
                        "steps": [
                            {
                                "name": "send-wake-apns",
                                "ok": False,
                                "stdout": json.dumps(
                                    {
                                        "ok": False,
                                        "stage": "backend-push-target",
                                        "channelId": "dummy-channel",
                                        "handle": "@dummy",
                                        "error": "push target lookup failed",
                                        "body": "not found",
                                    }
                                ),
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            summary = physical_device_boundary_status.read_run_summary(str(run))

        self.assertIsNotNone(summary)
        assert summary is not None
        self.assertFalse(summary["sendWakeApnsResult"]["ok"])
        self.assertEqual("backend-push-target", summary["sendWakeApnsResult"]["stage"])
        self.assertEqual("dummy-channel", summary["sendWakeApnsResult"]["channelId"])
        self.assertEqual("@dummy", summary["sendWakeApnsResult"]["handle"])
        self.assertIn("push target", summary["sendWakeApnsResult"]["error"])
        self.assertEqual("not found", summary["sendWakeApnsResult"]["body"])

    def test_priority_actions_include_send_wake_apns_result_for_lockscreen_rerun(self) -> None:
        actions = physical_device_boundary_status.priority_actions(
            {
                "lockscreen-apns-wake": {
                    "launchFailures": [],
                    "sendWakeApnsResult": {
                        "ok": False,
                        "stage": "backend-push-target",
                        "channelId": "dummy-channel",
                        "handle": "@dummy",
                        "error": "backend push-target request failed with HTTP 401",
                        "status": 401,
                        "body": '{"error":"not a channel member"}',
                    },
                    "targetCellProof": {
                        "missingEvidence": ["incoming push received on locked/background receiver"],
                    },
                }
            },
            {
                "lockscreen-apns-wake": {
                    "operatorRequirements": [{"name": "wake-channel-id"}],
                    "nextCommand": {"command": "just physical-device-boundary-collect ..."},
                    "latestRun": {
                        "targetCell": "lockscreen-apns-wake",
                        "sendWakeApnsResult": {
                            "ok": False,
                            "stage": "backend-push-target",
                            "channelId": "dummy-channel",
                            "handle": "@dummy",
                            "error": "backend push-target request failed with HTTP 401",
                            "status": 401,
                            "body": '{"error":"not a channel member"}',
                        },
                        "targetCellProof": {
                            "missingEvidence": ["incoming push received on locked/background receiver"],
                        },
                    },
                }
            },
            {"blockers": []},
        )

        self.assertEqual("rerun-missing-cell", actions[0]["kind"])
        self.assertEqual(
            "backend-push-target",
            actions[0]["sendWakeApnsResult"]["stage"],
        )
        self.assertEqual("dummy-channel", actions[0]["sendWakeApnsResult"]["channelId"])
        self.assertEqual("not-channel-member", actions[0]["wakeSendDiagnosis"]["kind"])
        self.assertIn("sender handle", actions[0]["wakeSendDiagnosis"]["remediation"])
        self.assertIn(
            "ptt-apns-print-only",
            actions[0]["wakeTargetPreflightCommand"]["command"],
        )

    def test_wake_send_diagnosis_classifies_missing_push_target(self) -> None:
        diagnosis = physical_device_boundary_status.wake_send_diagnosis(
            {
                "ok": False,
                "stage": "backend-push-target",
                "status": 404,
                "body": '{"error":"missing push target"}',
            }
        )

        self.assertEqual("push-target-not-found", diagnosis["kind"])
        self.assertIn("publish its push target", diagnosis["remediation"])

    def test_compact_steps_preserves_diagnostic_lines_without_raw_output(self) -> None:
        steps = physical_device_boundary_status.compact_steps(
            [
                {
                    "name": "device-launch-profile",
                    "ok": False,
                    "exitCode": 1,
                    "stdout": "normal\n** BUILD SUCCEEDED **\n",
                    "stderr": (
                        "== iPad (physical-2) ==\n"
                        "ERROR: The device disconnected immediately after connecting.\n"
                    ),
                }
            ]
        )

        self.assertEqual("device-launch-profile", steps[0]["name"])
        self.assertNotIn("stdout", steps[0])
        self.assertNotIn("stderr", steps[0])
        self.assertGreater(steps[0]["outputSummary"]["stdoutBytes"], 0)
        self.assertIn(
            "ERROR: The device disconnected immediately after connecting.",
            steps[0]["outputSummary"]["diagnosticLines"],
        )


if __name__ == "__main__":
    unittest.main()
