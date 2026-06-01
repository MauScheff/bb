#!/usr/bin/env python3

from __future__ import annotations

import json
import argparse
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import physical_device_boundary_collect


class PhysicalDeviceBoundaryCollectTests(unittest.TestCase):
    def test_discovers_device_artifacts_and_device_ids(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            device_dir = root / "Mauricios_iPhone"
            device_dir.mkdir()
            (device_dir / "manifest.json").write_text(
                json.dumps({"device": {"udid": "physical-udid", "name": "Mauricio's iPhone"}}),
                encoding="utf-8",
            )
            (device_dir / "beepbeep-diagnostics-tail.log").write_text(
                "PTT audio session activated",
                encoding="utf-8",
            )

            artifacts = physical_device_boundary_collect.discover_device_artifacts(root)
            devices = physical_device_boundary_collect.devices_from_device_manifests(artifacts)

        self.assertIn(str(device_dir / "manifest.json"), artifacts)
        self.assertIn(str(device_dir / "beepbeep-diagnostics-tail.log"), artifacts)
        self.assertEqual(["physical-udid"], devices)

    def test_main_writes_collection_summary_from_existing_artifact(self) -> None:
        original_argv = sys.argv
        original_run = physical_device_boundary_collect.subprocess.run
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                artifact = root / "merged-diagnostics.txt"
                artifact.write_text("PTT audio session activated", encoding="utf-8")
                summary = root / "summary.json"
                manifest = root / "manifest.json"
                proof = root / "proof.json"

                calls: list[list[str]] = []

                def fake_run(command: list[str], *, text: bool, capture_output: bool) -> subprocess.CompletedProcess[str]:
                    calls.append(command)
                    if "device_app.py" in " ".join(command) and "list" in command:
                        return subprocess.CompletedProcess(
                            command,
                            0,
                            stdout=json.dumps(
                                [
                                    {"name": "iPhone", "udid": "sender", "state": "connected"},
                                    {"name": "iPad", "udid": "receiver", "state": "connected"},
                                ]
                            ),
                            stderr="",
                        )
                    if "physical_device_boundary_manifest.py" in " ".join(command):
                        manifest.write_text(json.dumps({"cells": []}), encoding="utf-8")
                    if "physical_device_boundary_proof.py" in " ".join(command):
                        proof.write_text(
                            json.dumps(
                                {
                                    "status": "pass",
                                    "ok": True,
                                    "cells": [{"name": "foreground-ptt-audio", "status": "pass"}],
                                }
                            ),
                            encoding="utf-8",
                        )
                    return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

                physical_device_boundary_collect.subprocess.run = fake_run
                sys.argv = [
                    "physical_device_boundary_collect.py",
                    "--skip-device-diagnostics",
                    "--skip-intake",
                    "--artifact",
                    str(artifact),
                    "--physical-device",
                    "sender",
                    "--physical-device",
                    "receiver",
                    "--manifest-output",
                    str(manifest),
                    "--proof-output",
                    str(proof),
                    "--summary-output",
                    str(summary),
                ]

                exit_code = physical_device_boundary_collect.main()
                payload = json.loads(summary.read_text(encoding="utf-8"))

        finally:
            sys.argv = original_argv
            physical_device_boundary_collect.subprocess.run = original_run

        self.assertEqual(0, exit_code)
        self.assertEqual("pass", payload["status"])
        self.assertEqual(["sender", "receiver"], payload["physicalDevices"])
        self.assertEqual("current", payload["launchProfile"])
        self.assertEqual("", payload["evidenceSince"])
        self.assertFalse(payload["wakeApnsSent"])
        self.assertEqual([str(artifact)], payload["artifacts"])
        self.assertEqual(["foreground-ptt-audio"], payload["proofSummary"]["passedCells"])
        self.assertEqual(
            ["physical-device-boundary-manifest", "physical-device-boundary-proof"],
            [step["name"] for step in payload["steps"]],
        )
        self.assertEqual(2, len(calls))

    def test_launch_profile_environment_sets_direct_quic_overrides(self) -> None:
        env = physical_device_boundary_collect.launch_profile_environment("direct-quic")

        self.assertIn("--env", env)
        self.assertIn("TURBO_DEBUG_MEDIA_RELAY_ENABLED=0", env)
        self.assertIn("TURBO_DEBUG_FORCE_MEDIA_RELAY=0", env)
        self.assertIn("TURBO_DEBUG_DISABLE_DIRECT_QUIC_AUTO_UPGRADE=0", env)

    def test_target_cell_pass_makes_collection_pass_when_full_matrix_has_failures(self) -> None:
        original_argv = sys.argv
        original_run = physical_device_boundary_collect.subprocess.run
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                artifact = root / "merged-diagnostics.txt"
                artifact.write_text("Physical boundary launch profile transport=direct-quic", encoding="utf-8")
                summary = root / "summary.json"
                manifest = root / "manifest.json"
                proof = root / "proof.json"

                def fake_run(command: list[str], *, text: bool, capture_output: bool) -> subprocess.CompletedProcess[str]:
                    joined = " ".join(command)
                    if "physical_device_boundary_manifest.py" in joined:
                        manifest.write_text(json.dumps({"cells": []}), encoding="utf-8")
                    if "physical_device_boundary_proof.py" in joined:
                        proof.write_text(
                            json.dumps(
                                {
                                    "status": "fail",
                                    "ok": False,
                                    "cells": [
                                        {
                                            "name": "direct-quic-media",
                                            "status": "pass",
                                            "ok": True,
                                            "reason": "",
                                            "evidence": [
                                                {"check": "media routed over Direct QUIC", "ok": True}
                                            ],
                                            "context": [
                                                {"check": "Direct QUIC run configuration active", "ok": True}
                                            ],
                                        },
                                        {
                                            "name": "lockscreen-apns-wake",
                                            "status": "fail",
                                            "ok": False,
                                            "reason": "missing wake evidence",
                                        },
                                    ],
                                }
                            ),
                            encoding="utf-8",
                        )
                        return subprocess.CompletedProcess(command, 1, stdout="fail\n", stderr="")
                    return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

                physical_device_boundary_collect.subprocess.run = fake_run
                sys.argv = [
                    "physical_device_boundary_collect.py",
                    "--target-cell",
                    "direct-quic-media",
                    "--skip-device-diagnostics",
                    "--skip-intake",
                    "--skip-launch",
                    "--artifact",
                    str(artifact),
                    "--manifest-output",
                    str(manifest),
                    "--proof-output",
                    str(proof),
                    "--summary-output",
                    str(summary),
                ]

                exit_code = physical_device_boundary_collect.main()
                payload = json.loads(summary.read_text(encoding="utf-8"))

        finally:
            sys.argv = original_argv
            physical_device_boundary_collect.subprocess.run = original_run

        self.assertEqual(0, exit_code)
        self.assertTrue(payload["ok"])
        self.assertEqual("pass", payload["status"])
        self.assertEqual("fail", payload["proofSummary"]["status"])
        self.assertEqual("pass", payload["targetCellProof"]["status"])
        self.assertEqual(["lockscreen-apns-wake"], [cell["name"] for cell in payload["proofSummary"]["failedCells"]])

    def test_failed_direct_quic_cell_recommends_direct_quic_launch_profile(self) -> None:
        summary = physical_device_boundary_collect.summarize_proof(
            {
                "status": "fail",
                "cells": [
                    {"name": "direct-quic-media", "status": "fail", "reason": "missing direct media"}
                ],
            }
        )

        self.assertEqual(
            [
                {
                    "cell": "direct-quic-media",
                    "launchProfile": "direct-quic",
                    "reason": "Direct QUIC media proof requires a run without media relay forced.",
                }
            ],
            summary["recommendedNextRuns"],
        )

    def test_target_direct_quic_defaults_launch_profile_and_records_plan(self) -> None:
        original_argv = sys.argv
        original_run = physical_device_boundary_collect.subprocess.run
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                artifact = root / "merged-diagnostics.txt"
                artifact.write_text("directQuicIsActive=true", encoding="utf-8")
                summary = root / "summary.json"
                manifest = root / "manifest.json"
                proof = root / "proof.json"

                calls: list[list[str]] = []

                def fake_run(command: list[str], *, text: bool, capture_output: bool) -> subprocess.CompletedProcess[str]:
                    calls.append(command)
                    joined = " ".join(command)
                    if "device_app.py" in joined and "list" in command:
                        return subprocess.CompletedProcess(
                            command,
                            0,
                            stdout=json.dumps(
                                [
                                    {"name": "iPhone", "udid": "sender", "state": "connected"},
                                    {"name": "iPad", "udid": "receiver", "state": "connected"},
                                ]
                            ),
                            stderr="",
                        )
                    if "device_app.py" in joined and "launch-connected" in command:
                        output = Path(command[command.index("--output") + 1])
                        output.write_text(
                            json.dumps(
                                [
                                    {
                                        "ok": True,
                                        "device": {"name": "iPhone", "udid": "sender", "state": "connected"},
                                    },
                                    {
                                        "ok": True,
                                        "device": {"name": "iPad", "udid": "receiver", "state": "connected"},
                                    },
                                ]
                            ),
                            encoding="utf-8",
                        )
                        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
                    if "physical_device_boundary_manifest.py" in joined:
                        manifest.write_text(json.dumps({"cells": []}), encoding="utf-8")
                    if "physical_device_boundary_proof.py" in joined:
                        proof.write_text(
                            json.dumps(
                                {
                                    "status": "fail",
                                    "ok": False,
                                    "cells": [{"name": "direct-quic-media", "status": "fail"}],
                                }
                            ),
                            encoding="utf-8",
                        )
                        return subprocess.CompletedProcess(command, 1, stdout="fail\n", stderr="")
                    return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

                physical_device_boundary_collect.subprocess.run = fake_run
                sys.argv = [
                    "physical_device_boundary_collect.py",
                    "--target-cell",
                    "direct-quic-media",
                    "--skip-device-diagnostics",
                    "--skip-intake",
                    "--artifact",
                    str(artifact),
                    "--physical-device",
                    "sender",
                    "--physical-device",
                    "receiver",
                    "--manifest-output",
                    str(manifest),
                    "--proof-output",
                    str(proof),
                    "--summary-output",
                    str(summary),
                ]

                exit_code = physical_device_boundary_collect.main()
                payload = json.loads(summary.read_text(encoding="utf-8"))

        finally:
            sys.argv = original_argv
            physical_device_boundary_collect.subprocess.run = original_run

        self.assertEqual(1, exit_code)
        self.assertEqual("direct-quic-media", payload["targetCell"])
        self.assertEqual("direct-quic", payload["launchProfile"])
        self.assertEqual("direct-quic", payload["targetCellPlan"]["launchProfile"])
        self.assertEqual("device-list-preflight", payload["steps"][0]["name"])
        self.assertEqual("pass", payload["currentDevicePreflight"]["status"])
        self.assertEqual("not-collected", payload["currentLaunchabilityPreflight"]["status"])
        self.assertEqual("device-launch-profile", payload["steps"][1]["name"])
        self.assertIn("--continue-on-device-error", payload["steps"][1]["command"])
        self.assertIn("TURBO_DEBUG_MEDIA_RELAY_ENABLED=0", payload["steps"][1]["command"])
        self.assertEqual(4, len(calls))

    def test_target_lockscreen_requires_wake_sender_or_manual_override(self) -> None:
        original_argv = sys.argv
        try:
            sys.argv = [
                "physical_device_boundary_collect.py",
                "--target-cell",
                "lockscreen-apns-wake",
                "--skip-intake",
            ]

            with self.assertRaises(SystemExit):
                physical_device_boundary_collect.main()

        finally:
            sys.argv = original_argv

    def test_target_lockscreen_allows_external_manual_wake(self) -> None:
        args = argparse.Namespace(
            target_cell="lockscreen-apns-wake",
            launch_profile="current",
            allow_profile_mismatch=False,
            send_wake_apns=False,
            allow_manual_wake=True,
            skip_device_diagnostics=False,
            skip_launch=False,
        )

        plan = physical_device_boundary_collect.resolve_collection_plan(args)

        self.assertEqual("lockscreen-apns-wake", plan["targetCell"])
        self.assertEqual("current", plan["launchProfile"])
        self.assertIn("receiver", " ".join(plan["operatorSteps"]))

    def test_target_cell_rejects_wrong_profile_without_override(self) -> None:
        args = argparse.Namespace(
            target_cell="fallback-relay-audio",
            launch_profile="direct-quic",
            allow_profile_mismatch=False,
            send_wake_apns=False,
            allow_manual_wake=False,
            skip_device_diagnostics=False,
            skip_launch=False,
        )

        with self.assertRaises(SystemExit):
            physical_device_boundary_collect.resolve_collection_plan(args)

    def test_target_cell_defaults_proof_outputs_to_run_directory(self) -> None:
        args = argparse.Namespace(
            target_cell="direct-quic-media",
            manifest_output=physical_device_boundary_collect.DEFAULT_MANIFEST_OUTPUT,
            proof_output=physical_device_boundary_collect.DEFAULT_PROOF_OUTPUT,
        )

        manifest, proof = physical_device_boundary_collect.resolve_proof_outputs(
            args,
            Path("/tmp/target-run"),
        )

        self.assertEqual("/tmp/target-run/physical-device-boundaries-manifest.json", manifest)
        self.assertEqual("/tmp/target-run/physical-device-boundaries.json", proof)

    def test_target_launch_failure_records_operator_blocker_and_skips_wait(self) -> None:
        original_argv = sys.argv
        original_run = physical_device_boundary_collect.subprocess.run
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                summary = root / "summary.json"
                manifest = root / "manifest.json"
                proof = root / "proof.json"

                def fake_run(command: list[str], *, text: bool, capture_output: bool) -> subprocess.CompletedProcess[str]:
                    joined = " ".join(command)
                    if "device_app.py" in joined and "list" in command:
                        return subprocess.CompletedProcess(
                            command,
                            0,
                            stdout=json.dumps(
                                [
                                    {
                                        "name": "Mauricio’s iPhone",
                                        "udid": "00008030-0018786814D8802E",
                                        "state": "connected",
                                    },
                                    {
                                        "name": "iPad",
                                        "udid": "00008103-001478421153001E",
                                        "state": "connected",
                                    },
                                ]
                            ),
                            stderr="",
                        )
                    if "device_app.py" in joined and "run-connected" in command:
                        return subprocess.CompletedProcess(
                            command,
                            1,
                            stdout="",
                            stderr=(
                                "== Mauricio’s iPhone (00008030-0018786814D8802E) ==\n"
                                "Unable to launch because the device was not, or could not be, unlocked.\n"
                                "== iPad (00008103-001478421153001E) ==\n"
                                "Unable to launch because the device was not, or could not be, unlocked.\n"
                            ),
                        )
                    if "physical_device_boundary_manifest.py" in joined:
                        manifest.write_text(json.dumps({"cells": []}), encoding="utf-8")
                    if "physical_device_boundary_proof.py" in joined:
                        proof.write_text(
                            json.dumps(
                                {
                                    "status": "fail",
                                    "ok": False,
                                    "cells": [
                                        {
                                            "name": "direct-quic-media",
                                            "status": "fail",
                                            "ok": False,
                                            "reason": "missing direct-quic evidence",
                                            "evidence": [
                                                {
                                                    "check": "media routed over Direct QUIC",
                                                    "ok": False,
                                                }
                                            ],
                                            "context": [
                                                {
                                                    "check": "Direct QUIC run configuration active",
                                                    "ok": False,
                                                }
                                            ],
                                        }
                                    ],
                                }
                            ),
                            encoding="utf-8",
                        )
                        return subprocess.CompletedProcess(command, 1, stdout="fail\n", stderr="")
                    return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

                physical_device_boundary_collect.subprocess.run = fake_run
                sys.argv = [
                    "physical_device_boundary_collect.py",
                    "--target-cell",
                    "direct-quic-media",
                    "--skip-device-diagnostics",
                    "--skip-intake",
                    "--pre-collect-wait-seconds",
                    "60",
                    "--manifest-output",
                    str(manifest),
                    "--proof-output",
                    str(proof),
                    "--summary-output",
                    str(summary),
                ]

                exit_code = physical_device_boundary_collect.main()
                payload = json.loads(summary.read_text(encoding="utf-8"))

        finally:
            sys.argv = original_argv
            physical_device_boundary_collect.subprocess.run = original_run

        self.assertEqual(1, exit_code)
        self.assertIn("device locked", payload["operatorBlockers"][0])
        self.assertEqual(
            [
                {
                    "device": "Mauricio’s iPhone",
                    "message": "Unable to launch because the device was not, or could not be, unlocked.",
                    "reason": "locked",
                    "udid": "00008030-0018786814D8802E",
                },
                {
                    "device": "iPad",
                    "message": "Unable to launch because the device was not, or could not be, unlocked.",
                    "reason": "locked",
                    "udid": "00008103-001478421153001E",
                },
            ],
            payload["launchFailures"],
        )
        self.assertEqual(
            [
                "device-list-preflight",
                "device-launch-profile",
                "target-cell-interaction",
                "physical-device-boundary-manifest",
                "physical-device-boundary-proof",
            ],
            [step["name"] for step in payload["steps"]],
        )
        self.assertTrue(payload["steps"][2]["skipped"])
        self.assertEqual("not-collected", payload["currentLaunchabilityPreflight"]["status"])
        self.assertFalse(payload["wakeApnsSent"])
        self.assertEqual("direct-quic-media", payload["targetCellProof"]["name"])
        self.assertEqual("fail", payload["targetCellProof"]["status"])
        self.assertEqual(
            ["media routed over Direct QUIC"],
            payload["targetCellProof"]["missingEvidence"],
        )
        self.assertEqual(
            ["Direct QUIC run configuration active"],
            payload["targetCellProof"]["missingContext"],
        )
        commands = {command["name"]: command["command"] for command in payload["nextCommands"]}
        self.assertIn("physical-device-boundary-collect", commands["rerun-target-cell"])
        self.assertIn(" direct-quic ", commands["rerun-target-cell"])
        self.assertIn("--target-cell direct-quic-media", commands["rerun-target-cell"])
        self.assertIn(payload["outputDir"], commands["rerun-target-cell"])
        self.assertEqual(
            f"just physical-device-boundary-finalize {payload['outputDir']}",
            commands["finalize-canonical-physical-proof"],
        )

    def test_target_device_preflight_failure_skips_launch_when_second_device_missing(self) -> None:
        original_argv = sys.argv
        original_run = physical_device_boundary_collect.subprocess.run
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                summary = root / "summary.json"
                manifest = root / "manifest.json"
                proof = root / "proof.json"
                calls: list[list[str]] = []

                def fake_run(command: list[str], *, text: bool, capture_output: bool) -> subprocess.CompletedProcess[str]:
                    calls.append(command)
                    joined = " ".join(command)
                    if "device_app.py" in joined and "list" in command:
                        return subprocess.CompletedProcess(
                            command,
                            0,
                            stdout=json.dumps(
                                [
                                    {"name": "iPhone", "udid": "physical-1", "state": "connected"},
                                ]
                            ),
                            stderr="",
                        )
                    if "device_app.py" in joined and "run-connected" in command:
                        self.fail("launch should be skipped when current-device preflight fails")
                    if "physical_device_boundary_manifest.py" in joined:
                        manifest.write_text(json.dumps({"cells": []}), encoding="utf-8")
                    if "physical_device_boundary_proof.py" in joined:
                        proof.write_text(json.dumps({"status": "fail", "ok": False, "cells": []}), encoding="utf-8")
                        return subprocess.CompletedProcess(command, 1, stdout="fail\n", stderr="")
                    return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

                physical_device_boundary_collect.subprocess.run = fake_run
                sys.argv = [
                    "physical_device_boundary_collect.py",
                    "--target-cell",
                    "direct-quic-media",
                    "--skip-device-diagnostics",
                    "--skip-intake",
                    "--pre-collect-wait-seconds",
                    "60",
                    "--manifest-output",
                    str(manifest),
                    "--proof-output",
                    str(proof),
                    "--summary-output",
                    str(summary),
                ]

                exit_code = physical_device_boundary_collect.main()
                payload = json.loads(summary.read_text(encoding="utf-8"))

        finally:
            sys.argv = original_argv
            physical_device_boundary_collect.subprocess.run = original_run

        self.assertEqual(1, exit_code)
        self.assertEqual("fail", payload["currentDevicePreflight"]["status"])
        self.assertIn("fewer than two paired", payload["operatorBlockers"][0])
        self.assertEqual(
            [
                "device-list-preflight",
                "target-cell-interaction",
                "physical-device-boundary-manifest",
                "physical-device-boundary-proof",
            ],
            [step["name"] for step in payload["steps"]],
        )
        self.assertTrue(payload["steps"][1]["skipped"])

    def test_target_cell_summary_reports_missing_cells(self) -> None:
        summary = physical_device_boundary_collect.summarize_target_cell(
            {"status": "fail", "cells": []},
            "lockscreen-apns-wake",
        )

        self.assertEqual("lockscreen-apns-wake", summary["name"])
        self.assertEqual("missing", summary["status"])
        self.assertIn("not present", summary["reason"])

    def test_launch_failure_details_parse_locked_devices(self) -> None:
        failures = physical_device_boundary_collect.classify_launch_failure_details(
            {
                "stdout": "",
                "stderr": "\n".join(
                    [
                        "== Mauricio’s iPhone (00008030-0018786814D8802E) ==",
                        "BSErrorCodeDescription = Locked",
                        "== iPad (00008103-001478421153001E) ==",
                        "Unable to launch com.rounded.Turbo because the device was not, or could not be, unlocked.",
                    ]
                ),
            }
        )

        self.assertEqual("Mauricio’s iPhone", failures[0]["device"])
        self.assertEqual("00008030-0018786814D8802E", failures[0]["udid"])
        self.assertEqual("locked", failures[0]["reason"])
        self.assertEqual("iPad", failures[1]["device"])
        self.assertEqual("00008103-001478421153001E", failures[1]["udid"])

    def test_launch_failure_details_preserve_summary_only_device_failures(self) -> None:
        failures = physical_device_boundary_collect.classify_launch_failure_details(
            {
                "stdout": "",
                "stderr": (
                    "== Mauricio’s iPhone (00008030-0018786814D8802E) ==\n"
                    "BSErrorCodeDescription = Locked\n"
                    "== iPad (00008103-001478421153001E) ==\n"
                    "run-connected failed for device(s): "
                    "Mauricio’s iPhone (00008030-0018786814D8802E) exit=1; "
                    "iPad (00008103-001478421153001E) exit=1\n"
                ),
            }
        )

        by_udid = {failure["udid"]: failure for failure in failures}
        self.assertEqual("locked", by_udid["00008030-0018786814D8802E"]["reason"])
        self.assertEqual("device-command-failed", by_udid["00008103-001478421153001E"]["reason"])
        self.assertIn("exited 1", by_udid["00008103-001478421153001E"]["message"])

    def test_launch_failure_details_parse_device_disconnects(self) -> None:
        step = {
            "stdout": "",
            "stderr": (
                "== iPad (00008103-001478421153001E) ==\n"
                "ERROR: The device disconnected immediately after connecting. "
                "(com.apple.dt.CoreDeviceError error 4000 (0xFA0))\n"
                "run-connected failed for device(s): iPad (00008103-001478421153001E) exit=1\n"
            ),
        }

        failures = physical_device_boundary_collect.classify_launch_failure_details(step)
        blockers = physical_device_boundary_collect.classify_launch_failure(step)

        self.assertEqual("device-disconnected", failures[0]["reason"])
        self.assertIn("disconnected immediately", failures[0]["message"])
        self.assertIn("device disconnected during command", blockers[0])

    def test_next_collect_command_preserves_wake_args(self) -> None:
        args = physical_device_boundary_collect.parse_args(
            [
                "--target-cell",
                "lockscreen-apns-wake",
                "--allow-manual-wake",
                "--send-wake-apns",
                "--wake-channel-id",
                "channel-a",
                "--wake-handle",
                "@sender",
                "--physical-device",
                "sender-device",
                "--physical-device",
                "receiver-device",
                "--pre-collect-wait-seconds",
                "12",
            ]
        )

        command = physical_device_boundary_collect.just_collect_command(
            args,
            Path("/tmp/wake-run"),
        )

        self.assertIn("physical-device-boundary-collect", command)
        self.assertIn("--physical-device sender-device", command)
        self.assertIn("--send-wake-apns", command)
        self.assertIn("--wake-channel-id channel-a", command)
        self.assertIn("--wake-handle @sender", command)
        self.assertIn("--target-cell lockscreen-apns-wake", command)
        self.assertIn("--allow-manual-wake", command)

    def test_wake_apns_sent_reflects_successful_send_step(self) -> None:
        original_argv = sys.argv
        original_run = physical_device_boundary_collect.subprocess.run
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                summary = root / "summary.json"
                manifest = root / "manifest.json"
                proof = root / "proof.json"

                def fake_run(command: list[str], *, text: bool, capture_output: bool) -> subprocess.CompletedProcess[str]:
                    joined = " ".join(command)
                    if "device_app.py" in joined and "list" in command:
                        return subprocess.CompletedProcess(
                            command,
                            0,
                            stdout=json.dumps(
                                [
                                    {"name": "iPhone", "udid": "physical-1", "state": "connected"},
                                    {"name": "iPad", "udid": "physical-2", "state": "connected"},
                                ]
                            ),
                            stderr="",
                        )
                    if "send_ptt_apns.py" in joined and "--check-credentials" in command:
                        return subprocess.CompletedProcess(
                            command,
                            0,
                            stdout=json.dumps(
                                {
                                    "ok": True,
                                    "missing": [],
                                    "hasTeamId": True,
                                    "hasKeyId": True,
                                    "hasInlinePrivateKey": True,
                                    "hasPrivateKeyPath": False,
                                    "privateKeyPathExists": None,
                                }
                            ),
                            stderr="",
                        )
                    if "send_ptt_apns.py" in joined:
                        return subprocess.CompletedProcess(command, 1, stdout="", stderr="apns failed")
                    if "physical_device_boundary_manifest.py" in joined:
                        manifest.write_text(json.dumps({"cells": []}), encoding="utf-8")
                    if "physical_device_boundary_proof.py" in joined:
                        proof.write_text(json.dumps({"status": "fail", "ok": False, "cells": []}), encoding="utf-8")
                        return subprocess.CompletedProcess(command, 1, stdout="fail\n", stderr="")
                    return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

                physical_device_boundary_collect.subprocess.run = fake_run
                sys.argv = [
                    "physical_device_boundary_collect.py",
                    "--skip-launch",
                    "--skip-device-diagnostics",
                    "--skip-intake",
                    "--send-wake-apns",
                    "--wake-channel-id",
                    "channel",
                    "--wake-handle",
                    "@sender",
                    "--manifest-output",
                    str(manifest),
                    "--proof-output",
                    str(proof),
                    "--summary-output",
                    str(summary),
                ]

                exit_code = physical_device_boundary_collect.main()
                payload = json.loads(summary.read_text(encoding="utf-8"))

        finally:
            sys.argv = original_argv
            physical_device_boundary_collect.subprocess.run = original_run

        self.assertEqual(1, exit_code)
        self.assertFalse(payload["wakeApnsSent"])
        self.assertEqual("pass", payload["apnsCredentialPreflight"]["status"])

    def test_wake_apns_missing_credentials_skips_send_step(self) -> None:
        original_argv = sys.argv
        original_run = physical_device_boundary_collect.subprocess.run
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                summary = root / "summary.json"
                manifest = root / "manifest.json"
                proof = root / "proof.json"

                def fake_run(command: list[str], *, text: bool, capture_output: bool) -> subprocess.CompletedProcess[str]:
                    joined = " ".join(command)
                    if "device_app.py" in joined and "list" in command:
                        return subprocess.CompletedProcess(
                            command,
                            0,
                            stdout=json.dumps(
                                [
                                    {"name": "iPhone", "udid": "physical-1", "state": "connected"},
                                    {"name": "iPad", "udid": "physical-2", "state": "connected"},
                                ]
                            ),
                            stderr="",
                        )
                    if "send_ptt_apns.py" in joined and "--check-credentials" in command:
                        return subprocess.CompletedProcess(
                            command,
                            1,
                            stdout=json.dumps(
                                {
                                    "ok": False,
                                    "missing": ["TURBO_APNS_TEAM_ID"],
                                    "hasTeamId": False,
                                    "hasKeyId": True,
                                    "hasInlinePrivateKey": True,
                                }
                            ),
                            stderr="",
                        )
                    if "send_ptt_apns.py" in joined:
                        self.fail("wake send should be skipped when APNs credential preflight fails")
                    if "physical_device_boundary_manifest.py" in joined:
                        manifest.write_text(json.dumps({"cells": []}), encoding="utf-8")
                    if "physical_device_boundary_proof.py" in joined:
                        proof.write_text(json.dumps({"status": "fail", "ok": False, "cells": []}), encoding="utf-8")
                        return subprocess.CompletedProcess(command, 1, stdout="fail\n", stderr="")
                    return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

                physical_device_boundary_collect.subprocess.run = fake_run
                sys.argv = [
                    "physical_device_boundary_collect.py",
                    "--target-cell",
                    "lockscreen-apns-wake",
                    "--skip-launch",
                    "--skip-device-diagnostics",
                    "--skip-intake",
                    "--send-wake-apns",
                    "--wake-channel-id",
                    "channel",
                    "--wake-handle",
                    "@sender",
                    "--manifest-output",
                    str(manifest),
                    "--proof-output",
                    str(proof),
                    "--summary-output",
                    str(summary),
                ]

                exit_code = physical_device_boundary_collect.main()
                payload = json.loads(summary.read_text(encoding="utf-8"))

        finally:
            sys.argv = original_argv
            physical_device_boundary_collect.subprocess.run = original_run

        self.assertEqual(1, exit_code)
        self.assertFalse(payload["wakeApnsSent"])
        self.assertEqual("fail", payload["apnsCredentialPreflight"]["status"])
        self.assertIn("TURBO_APNS_TEAM_ID", payload["apnsCredentialPreflight"]["missing"])
        self.assertIn("APNs credentials missing", payload["operatorBlockers"][0])
        self.assertEqual(
            [
                "device-list-preflight",
                "wake-apns-credential-preflight",
                "send-wake-apns",
                "physical-device-boundary-manifest",
                "physical-device-boundary-proof",
            ],
            [step["name"] for step in payload["steps"]],
        )
        self.assertTrue(payload["steps"][2]["skipped"])

    def test_send_wake_apns_requires_channel_and_handle(self) -> None:
        original_argv = sys.argv
        try:
            sys.argv = [
                "physical_device_boundary_collect.py",
                "--skip-device-diagnostics",
                "--skip-intake",
                "--send-wake-apns",
            ]

            with self.assertRaises(SystemExit):
                physical_device_boundary_collect.main()

        finally:
            sys.argv = original_argv

    def test_wait_step_records_elapsed_time(self) -> None:
        step = physical_device_boundary_collect.wait_step("short-wait", 0.0)

        self.assertEqual("short-wait", step["name"])
        self.assertTrue(step["ok"])

    def test_fresh_device_collection_uses_run_start_as_evidence_since(self) -> None:
        args = argparse.Namespace(skip_device_diagnostics=False)

        self.assertEqual(
            "2026-06-01T00:00:00Z",
            physical_device_boundary_collect.evidence_since(args, "2026-06-01T00:00:00Z"),
        )


if __name__ == "__main__":
    unittest.main()
