#!/usr/bin/env python3

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import physical_device_boundary_finalize


class PhysicalDeviceBoundaryFinalizeTests(unittest.TestCase):
    def test_cli_rejects_empty_input_to_avoid_clobbering_canonical_manifest(self) -> None:
        original_argv = sys.argv
        try:
            sys.argv = ["physical_device_boundary_finalize.py"]

            with self.assertRaises(SystemExit):
                physical_device_boundary_finalize.main()

        finally:
            sys.argv = original_argv

    def test_finalize_writes_summary_from_merge_and_proof_steps(self) -> None:
        original_argv = sys.argv
        original_run = physical_device_boundary_finalize.subprocess.run
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                manifest = root / "manifest.json"
                proof = root / "proof.json"
                summary = root / "summary.json"
                input_manifest = root / "input-manifest.json"
                missing_run_slot = root / "turbo-physical-fallback-relay-run"
                input_manifest.write_text(json.dumps({"cells": []}), encoding="utf-8")
                calls: list[list[str]] = []

                def fake_run(command: list[str], *, text: bool, capture_output: bool) -> subprocess.CompletedProcess[str]:
                    calls.append(command)
                    joined = " ".join(command)
                    if "physical_device_boundary_merge.py" in joined:
                        manifest.write_text(json.dumps({"cells": []}), encoding="utf-8")
                    if "physical_device_boundary_proof.py" in joined:
                        proof.write_text(
                            json.dumps(
                                {
                                    "status": "pass",
                                    "ok": True,
                                    "manifestEvidenceSince": "2026-06-01T04:00:00Z",
                                    "sourceEvidenceWindows": [
                                        {
                                            "sourceManifest": str(input_manifest),
                                            "evidenceSince": "2026-06-01T04:00:00Z",
                                        }
                                    ],
                                    "cells": [{"name": "foreground-ptt-audio", "status": "pass"}],
                                }
                            ),
                            encoding="utf-8",
                        )
                    return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

                physical_device_boundary_finalize.subprocess.run = fake_run
                sys.argv = [
                    "physical_device_boundary_finalize.py",
                    "--manifest-output",
                    str(manifest),
                    "--proof-output",
                    str(proof),
                    "--summary-output",
                    str(summary),
                    str(missing_run_slot),
                    str(input_manifest),
                ]

                exit_code = physical_device_boundary_finalize.main()
                payload = json.loads(summary.read_text(encoding="utf-8"))

        finally:
            sys.argv = original_argv
            physical_device_boundary_finalize.subprocess.run = original_run

        self.assertEqual(0, exit_code)
        self.assertEqual("pass", payload["status"])
        self.assertEqual([str(input_manifest)], payload["resolvedManifests"])
        self.assertEqual([str(missing_run_slot)], payload["skippedMissingInputs"])
        self.assertEqual(["foreground-ptt-audio"], payload["proofSummary"]["passedCells"])
        self.assertEqual("2026-06-01T04:00:00Z", payload["proofSummary"]["manifestEvidenceSince"])
        self.assertEqual("2026-06-01T04:00:00Z", payload["proofSummary"]["sourceEvidenceWindows"][0]["evidenceSince"])
        self.assertEqual(
            ["physical-device-boundary-merge", "physical-device-boundary-proof"],
            [step["name"] for step in payload["steps"]],
        )
        self.assertEqual(2, len(calls))


if __name__ == "__main__":
    unittest.main()
