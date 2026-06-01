#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import physical_device_boundary_proof


class PhysicalDeviceBoundaryProofTests(unittest.TestCase):
    def test_valid_manifest_passes_all_required_cells(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = self._manifest(root)

            result = physical_device_boundary_proof.validate_cells(manifest, root / "manifest.json")

        self.assertTrue(all(cell["status"] == "pass" for cell in result))

    def test_placeholder_devices_fail_even_with_existing_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = self._manifest(root)
            manifest["cells"][0]["devices"] = ["<sender-device-id>", "<receiver-device-id>"]

            result = physical_device_boundary_proof.validate_cells(manifest, root / "manifest.json")

        foreground = result[0]
        self.assertEqual(foreground["name"], "foreground-ptt-audio")
        self.assertEqual(foreground["status"], "fail")
        self.assertIn("device ids contain placeholders", foreground["reason"])

    def test_missing_required_check_fails_cell(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = self._manifest(root)
            manifest["cells"][2]["checks"] = ["fresh Direct QUIC identity projected"]

            result = physical_device_boundary_proof.validate_cells(manifest, root / "manifest.json")

        direct_quic = result[2]
        self.assertEqual(direct_quic["name"], "direct-quic-media")
        self.assertEqual(direct_quic["status"], "fail")
        self.assertIn("media routed over Direct QUIC", direct_quic["missingChecks"])
        self.assertIn("packet audio received and scheduled", direct_quic["missingChecks"])

    def test_missing_evidence_anchor_fails_cell(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = self._manifest(root)
            manifest["cells"][0]["evidence"]["sender reaches PTT audio session activated"] = [
                {
                    "artifact": str(root / "foreground-ptt-audio.json"),
                    "anchors": ["this anchor is absent"],
                }
            ]

            result = physical_device_boundary_proof.validate_cells(manifest, root / "manifest.json")

        foreground = result[0]
        self.assertEqual(foreground["name"], "foreground-ptt-audio")
        self.assertEqual(foreground["status"], "fail")
        self.assertIn("missing required evidence anchors", foreground["reason"])

    def test_missing_context_anchor_fails_cell(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = self._manifest(root)
            manifest["cells"][2]["context"]["Direct QUIC run configuration active"] = [
                {
                    "artifact": str(root / "direct-quic-media.json"),
                    "anchors": ["this context is absent"],
                }
            ]

            result = physical_device_boundary_proof.validate_cells(manifest, root / "manifest.json")

        direct_quic = result[2]
        self.assertEqual(direct_quic["name"], "direct-quic-media")
        self.assertEqual(direct_quic["status"], "fail")
        self.assertIn("missing required context anchors", direct_quic["reason"])

    def test_template_includes_evidence_and_context_anchor_placeholders(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "manifest.json"

            physical_device_boundary_proof.write_template(path)
            manifest = json.loads(path.read_text(encoding="utf-8"))

        for cell in manifest["cells"]:
            evidence = cell["evidence"]
            for check in physical_device_boundary_proof.REQUIRED_CELL_CHECKS[cell["name"]]:
                self.assertIn(check, evidence)
                self.assertIn("anchors", evidence[check][0])
            context = cell["context"]
            for context_name in physical_device_boundary_proof.REQUIRED_CELL_CONTEXTS.get(cell["name"], {}):
                self.assertIn(context_name, context)
                self.assertIn("anchors", context[context_name][0])

    def test_cli_carries_manifest_evidence_window_into_proof_artifact(self) -> None:
        original_argv = sys.argv
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                manifest_path = root / "manifest.json"
                output_path = root / "proof.json"
                manifest = self._manifest(root)
                manifest["evidenceSince"] = "2026-06-01T04:00:00Z"
                manifest["sourceEvidenceWindows"] = [
                    {
                        "sourceManifest": "/tmp/run/physical-device-boundaries-manifest.json",
                        "evidenceSince": "2026-06-01T04:00:00Z",
                    }
                ]
                manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
                sys.argv = [
                    "physical_device_boundary_proof.py",
                    "--manifest",
                    str(manifest_path),
                    "--output",
                    str(output_path),
                ]

                exit_code = physical_device_boundary_proof.main()
                payload = json.loads(output_path.read_text(encoding="utf-8"))

        finally:
            sys.argv = original_argv

        self.assertEqual(0, exit_code)
        self.assertEqual("2026-06-01T04:00:00Z", payload["manifestEvidenceSince"])
        self.assertEqual(
            "2026-06-01T04:00:00Z",
            payload["sourceEvidenceWindows"][0]["evidenceSince"],
        )

    def test_validate_cell_carries_source_evidence_window(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = self._manifest(root)
            manifest["cells"][0]["sourceManifests"] = ["/tmp/run/manifest.json"]
            manifest["cells"][0]["sourceEvidenceSince"] = "2026-06-01T04:00:00Z"

            result = physical_device_boundary_proof.validate_cells(manifest, root / "manifest.json")

        self.assertEqual(["/tmp/run/manifest.json"], result[0]["sourceManifests"])
        self.assertEqual("2026-06-01T04:00:00Z", result[0]["sourceEvidenceSince"])

    def _manifest(self, root: Path) -> dict[str, object]:
        cells = []
        for cell_name in physical_device_boundary_proof.REQUIRED_CELLS:
            artifact = root / f"{cell_name}.json"
            artifact.write_text(
                "\n".join(physical_device_boundary_proof.REQUIRED_CELL_CHECKS[cell_name]),
                encoding="utf-8",
            )
            cells.append(
                {
                    "name": cell_name,
                    "status": "pass",
                    "devices": ["iphone-avery-physical", "iphone-blake-physical"],
                    "artifacts": [str(artifact)],
                    "checks": physical_device_boundary_proof.REQUIRED_CELL_CHECKS[cell_name],
                    "evidence": {
                        check: [
                            {
                                "artifact": str(artifact),
                                "anchors": [check],
                            }
                        ]
                        for check in physical_device_boundary_proof.REQUIRED_CELL_CHECKS[cell_name]
                    },
                    "context": {
                        context_name: [
                            {
                                "artifact": str(artifact),
                                "anchors": [context_name],
                            }
                        ]
                        for context_name in physical_device_boundary_proof.REQUIRED_CELL_CONTEXTS.get(cell_name, {})
                    },
                }
            )
            with artifact.open("a", encoding="utf-8") as handle:
                for context_name in physical_device_boundary_proof.REQUIRED_CELL_CONTEXTS.get(cell_name, {}):
                    handle.write(f"\n{context_name}")
        return {
            "schemaVersion": 1,
            "devices": ["iphone-avery-physical", "iphone-blake-physical"],
            "cells": cells,
        }


if __name__ == "__main__":
    unittest.main()
