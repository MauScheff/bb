#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import physical_device_boundary_proof


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Merge physical-device boundary manifests cell-by-cell. A cell is promoted "
            "only when the existing physical-device proof validator accepts that cell."
        )
    )
    parser.add_argument(
        "manifests",
        nargs="*",
        help=(
            "Manifest paths, physical-device collection summary JSON files, or "
            "collection run directories to merge, in priority order."
        ),
    )
    parser.add_argument(
        "--manifest",
        action="append",
        default=[],
        help="Additional manifest, collection summary, or run directory to merge. Later positional inputs keep their order.",
    )
    parser.add_argument(
        "--output",
        default="/tmp/turbo-physical-device-boundaries-manifest.json",
        help="Merged manifest output path.",
    )
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="Exit nonzero unless every required cell in the merged manifest validates.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest_paths = resolve_manifest_paths([*args.manifest, *args.manifests])
    if not manifest_paths:
        raise SystemExit("at least one manifest, collection summary, or run directory is required")
    manifests = [read_manifest(path) for path in manifest_paths]
    merged = merge_manifests(manifests)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    validated = physical_device_boundary_proof.validate_cells(merged, output)
    passing = [cell["name"] for cell in validated if cell.get("status") == "pass"]
    failing = [cell["name"] for cell in validated if cell.get("status") != "pass"]
    print(f"physical-device boundary merged manifest: {output}")
    print(f"passing cells: {', '.join(passing) if passing else '(none)'}")
    print(f"incomplete cells: {', '.join(failing) if failing else '(none)'}")
    return 1 if args.require_complete and failing else 0


def resolve_manifest_paths(inputs: list[str]) -> list[str]:
    paths: list[str] = []
    for raw_input in inputs:
        if not raw_input:
            continue
        path = Path(raw_input)
        if not path.exists() and is_optional_physical_run_slot(path):
            continue
        if path.is_dir():
            paths.extend(paths_from_run_directory(path))
        elif path.name == "physical-device-boundary-collect.json":
            paths.extend(paths_from_collect_summary(path))
        else:
            paths.append(str(path))
    return dedupe(paths)


def skipped_optional_run_slots(inputs: list[str]) -> list[str]:
    return [
        str(Path(raw_input))
        for raw_input in inputs
        if raw_input and not Path(raw_input).exists() and is_optional_physical_run_slot(Path(raw_input))
    ]


def is_optional_physical_run_slot(path: Path) -> bool:
    return path.name in {
        "turbo-physical-direct-quic-run",
        "turbo-physical-direct-quic-run-current",
        "turbo-physical-lockscreen-wake-run",
        "turbo-physical-fallback-relay-run",
        "turbo-physical-foreground-ptt-run",
        "turbo-physical-device-boundary-run",
        "turbo-physical-device-boundary-run-current",
    }


def paths_from_run_directory(path: Path) -> list[str]:
    summary = path / "physical-device-boundary-collect.json"
    if summary.exists():
        return paths_from_collect_summary(summary)
    candidates = [
        path / "physical-device-boundaries-manifest.json",
        path / "manifest.json",
    ]
    return [str(candidate) for candidate in candidates if candidate.exists()]


def paths_from_collect_summary(path: Path) -> list[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit(f"collection summary is not a JSON object: {path}")
    manifest = payload.get("manifest")
    if not isinstance(manifest, str) or not manifest.strip():
        raise SystemExit(f"collection summary does not include a manifest path: {path}")
    manifest_path = Path(manifest)
    if not manifest_path.is_absolute():
        manifest_path = path.parent / manifest_path
    return [str(manifest_path)]


def read_manifest(path: str) -> dict[str, Any]:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit(f"manifest is not a JSON object: {path}")
    payload["_sourceManifest"] = str(Path(path))
    return payload


def merge_manifests(manifests: list[dict[str, Any]]) -> dict[str, Any]:
    selected_cells = [
        select_cell(cell_name, manifests)
        for cell_name in physical_device_boundary_proof.REQUIRED_CELLS
    ]
    devices = dedupe(
        [
            str(device)
            for manifest in manifests
            for device in list_value(manifest.get("devices"))
        ]
    )
    artifacts = dedupe(
        [
            str(artifact)
            for cell in selected_cells
            for artifact in list_value(cell.get("artifacts"))
        ]
    )
    source_evidence_windows = [
        {
            "sourceManifest": str(manifest.get("_sourceManifest") or ""),
            "evidenceSince": str(manifest.get("evidenceSince") or ""),
        }
        for manifest in manifests
        if str(manifest.get("_sourceManifest") or "")
    ]
    return {
        "schemaVersion": 1,
        "createdAt": utc_now(),
        "sourceManifests": [
            str(manifest.get("_sourceManifest") or "")
            for manifest in manifests
            if str(manifest.get("_sourceManifest") or "")
        ],
        "sourceEvidenceWindows": source_evidence_windows,
        "devices": devices,
        "artifacts": artifacts,
        "cells": selected_cells,
    }


def select_cell(cell_name: str, manifests: list[dict[str, Any]]) -> dict[str, Any]:
    candidates = candidate_cells(cell_name, manifests)
    for source, cell in candidates:
        result = physical_device_boundary_proof.validate_cell(cell_name, cell)
        if result.get("status") == "pass":
            return with_source(cell, source)
    if candidates:
        return with_source(candidates[0][1], candidates[0][0])
    return empty_cell(cell_name)


def candidate_cells(
    cell_name: str,
    manifests: list[dict[str, Any]],
) -> list[tuple[str, dict[str, Any]]]:
    candidates: list[tuple[str, dict[str, Any]]] = []
    for manifest in manifests:
        source = str(manifest.get("_sourceManifest") or "")
        for raw_cell in list_value(manifest.get("cells")):
            if isinstance(raw_cell, dict) and raw_cell.get("name") == cell_name:
                candidates.append((source, raw_cell))
    return candidates


def with_source(cell: dict[str, Any], source: str) -> dict[str, Any]:
    copied = json.loads(json.dumps(cell))
    sources = [
        str(value)
        for value in list_value(copied.get("sourceManifests"))
        if str(value)
    ]
    if source and source not in sources:
        sources.append(source)
    copied["sourceManifests"] = sources
    if source and copied.get("sourceEvidenceSince") is None:
        copied["sourceEvidenceSince"] = source_evidence_since(source)
    return copied


def source_evidence_since(source: str) -> str:
    try:
        payload = json.loads(Path(source).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    if not isinstance(payload, dict):
        return ""
    return str(payload.get("evidenceSince") or "")


def empty_cell(cell_name: str) -> dict[str, Any]:
    return {
        "name": cell_name,
        "status": "pending",
        "ok": False,
        "devices": [],
        "artifacts": [],
        "checks": physical_device_boundary_proof.REQUIRED_CELL_CHECKS[cell_name],
        "evidence": {
            check: []
            for check in physical_device_boundary_proof.REQUIRED_CELL_CHECKS[cell_name]
        },
        "context": {
            context_name: []
            for context_name in physical_device_boundary_proof.REQUIRED_CELL_CONTEXTS.get(cell_name, {})
        },
        "sourceManifests": [],
    }


def list_value(raw: Any) -> list[Any]:
    return raw if isinstance(raw, list) else []


def dedupe(items: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
