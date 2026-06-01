#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import physical_device_boundary_merge
import physical_device_boundary_proof


class PhysicalDeviceBoundaryMergeTests(unittest.TestCase):
    def test_merge_promotes_valid_cells_from_separate_manifests(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            first = self._manifest_with_cells(root, "first", ["foreground-ptt-audio"])
            second = self._manifest_with_cells(root, "second", ["direct-quic-media"])

            merged = physical_device_boundary_merge.merge_manifests(
                [
                    physical_device_boundary_merge.read_manifest(str(first)),
                    physical_device_boundary_merge.read_manifest(str(second)),
                ]
            )
            results = physical_device_boundary_proof.validate_cells(merged, root / "merged.json")

        by_name = {cell["name"]: cell for cell in results}
        self.assertEqual("pass", by_name["foreground-ptt-audio"]["status"])
        self.assertEqual("pass", by_name["direct-quic-media"]["status"])
        self.assertEqual("fail", by_name["lockscreen-apns-wake"]["status"])
        self.assertEqual("fail", by_name["fallback-relay-audio"]["status"])
        selected = {cell["name"]: cell for cell in merged["cells"]}
        self.assertEqual([str(first)], selected["foreground-ptt-audio"]["sourceManifests"])
        self.assertEqual([str(second)], selected["direct-quic-media"]["sourceManifests"])
        self.assertEqual("2026-06-01T00:00:00Z", selected["foreground-ptt-audio"]["sourceEvidenceSince"])
        self.assertEqual("2026-06-01T00:00:00Z", merged["sourceEvidenceWindows"][0]["evidenceSince"])

    def test_merge_does_not_promote_invalid_later_cell_over_valid_earlier_cell(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            valid = self._manifest_with_cells(root, "valid", ["direct-quic-media"])
            invalid = self._manifest_with_cells(root, "invalid", ["direct-quic-media"])
            payload = json.loads(invalid.read_text(encoding="utf-8"))
            payload["cells"][0]["evidence"]["media routed over Direct QUIC"] = []
            invalid.write_text(json.dumps(payload), encoding="utf-8")

            merged = physical_device_boundary_merge.merge_manifests(
                [
                    physical_device_boundary_merge.read_manifest(str(valid)),
                    physical_device_boundary_merge.read_manifest(str(invalid)),
                ]
            )

        selected = {cell["name"]: cell for cell in merged["cells"]}
        self.assertEqual([str(valid)], selected["direct-quic-media"]["sourceManifests"])

    def test_merge_keeps_first_pending_cell_when_no_candidate_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            first = self._manifest_with_cells(root, "first", ["direct-quic-media"])
            second = self._manifest_with_cells(root, "second", ["direct-quic-media"])
            for path in [first, second]:
                payload = json.loads(path.read_text(encoding="utf-8"))
                payload["cells"][0]["evidence"]["media routed over Direct QUIC"] = []
                path.write_text(json.dumps(payload), encoding="utf-8")

            merged = physical_device_boundary_merge.merge_manifests(
                [
                    physical_device_boundary_merge.read_manifest(str(first)),
                    physical_device_boundary_merge.read_manifest(str(second)),
                ]
            )

        selected = {cell["name"]: cell for cell in merged["cells"]}
        self.assertEqual([str(first)], selected["direct-quic-media"]["sourceManifests"])

    def test_missing_cells_are_emitted_as_pending(self) -> None:
        merged = physical_device_boundary_merge.merge_manifests([])

        self.assertEqual(
            physical_device_boundary_proof.REQUIRED_CELLS,
            [cell["name"] for cell in merged["cells"]],
        )
        self.assertTrue(all(cell["status"] == "pending" for cell in merged["cells"]))

    def test_cli_rejects_empty_input_to_avoid_clobbering_canonical_manifest(self) -> None:
        original_argv = sys.argv
        try:
            sys.argv = ["physical_device_boundary_merge.py"]

            with self.assertRaises(SystemExit):
                physical_device_boundary_merge.main()

        finally:
            sys.argv = original_argv

    def test_resolve_manifest_paths_accepts_run_directory_and_collect_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = self._manifest_with_cells(root, "run", ["foreground-ptt-audio"])
            run_dir = root / "run-dir"
            run_dir.mkdir()
            summary = run_dir / "physical-device-boundary-collect.json"
            summary.write_text(
                json.dumps({"manifest": str(manifest)}),
                encoding="utf-8",
            )

            paths = physical_device_boundary_merge.resolve_manifest_paths(
                [str(run_dir), str(summary), str(manifest)]
            )

        self.assertEqual([str(manifest)], paths)

    def test_collect_summary_relative_manifest_path_is_relative_to_summary_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = self._manifest_with_cells(root, "relative", ["foreground-ptt-audio"])
            summary = root / "physical-device-boundary-collect.json"
            summary.write_text(
                json.dumps({"manifest": manifest.name}),
                encoding="utf-8",
            )

            paths = physical_device_boundary_merge.resolve_manifest_paths([str(summary)])

        self.assertEqual([str(manifest)], paths)

    def test_resolve_manifest_paths_skips_known_missing_optional_run_slots(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = self._manifest_with_cells(root, "run", ["foreground-ptt-audio"])
            missing_optional = root / "turbo-physical-fallback-relay-run"

            paths = physical_device_boundary_merge.resolve_manifest_paths(
                [str(missing_optional), str(manifest)]
            )

        self.assertEqual([str(manifest)], paths)

    def test_resolve_manifest_paths_keeps_missing_explicit_manifest_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            missing_manifest = Path(temp_dir) / "missing-manifest.json"

            paths = physical_device_boundary_merge.resolve_manifest_paths([str(missing_manifest)])

        self.assertEqual([str(missing_manifest)], paths)

    def test_skipped_optional_run_slots_reports_missing_known_slots(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            missing_optional = Path(temp_dir) / "turbo-physical-foreground-ptt-run"
            missing_manifest = Path(temp_dir) / "missing-manifest.json"

            skipped = physical_device_boundary_merge.skipped_optional_run_slots(
                [str(missing_optional), str(missing_manifest)]
            )

        self.assertEqual([str(missing_optional)], skipped)

    def _manifest_with_cells(self, root: Path, name: str, cell_names: list[str]) -> Path:
        cells = [self._valid_cell(root, name, cell_name) for cell_name in cell_names]
        path = root / f"{name}.json"
        path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "evidenceSince": "2026-06-01T00:00:00Z",
                    "devices": ["iphone-a", "iphone-b"],
                    "cells": cells,
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        return path

    def _valid_cell(self, root: Path, manifest_name: str, cell_name: str) -> dict[str, object]:
        artifact = root / f"{manifest_name}-{cell_name}.txt"
        checks = physical_device_boundary_proof.REQUIRED_CELL_CHECKS[cell_name]
        contexts = list(physical_device_boundary_proof.REQUIRED_CELL_CONTEXTS.get(cell_name, {}))
        artifact.write_text("\n".join([*checks, *contexts]), encoding="utf-8")
        return {
            "name": cell_name,
            "status": "pass",
            "ok": True,
            "devices": ["iphone-a", "iphone-b"],
            "artifacts": [str(artifact)],
            "checks": checks,
            "evidence": {
                check: [{"artifact": str(artifact), "anchors": [check]}]
                for check in checks
            },
            "context": {
                context: [{"artifact": str(artifact), "anchors": [context]}]
                for context in contexts
            },
        }


if __name__ == "__main__":
    unittest.main()
