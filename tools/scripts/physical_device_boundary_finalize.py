#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

import physical_device_boundary_merge


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Finalize physical-device boundary evidence by merging manifests, "
            "running the canonical proof, and writing a summary artifact."
        )
    )
    parser.add_argument(
        "inputs",
        nargs="*",
        help="Manifest paths, collection summaries, or run directories to merge.",
    )
    parser.add_argument(
        "--manifest-output",
        default="/tmp/turbo-physical-device-boundaries-manifest.json",
        help="Canonical merged manifest output path.",
    )
    parser.add_argument(
        "--proof-output",
        default="/tmp/turbo-physical-device-boundaries.json",
        help="Canonical proof output path.",
    )
    parser.add_argument(
        "--summary-output",
        default="/tmp/turbo-physical-device-boundary-finalize.json",
        help="Finalize summary output path.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[2]
    resolved_inputs = physical_device_boundary_merge.resolve_manifest_paths(args.inputs)
    skipped_missing_inputs = physical_device_boundary_merge.skipped_optional_run_slots(args.inputs)
    if not resolved_inputs:
        raise SystemExit("at least one manifest, collection summary, or run directory is required")
    steps: list[dict[str, Any]] = []
    merge_step = run_step(
        "physical-device-boundary-merge",
        [
            sys.executable,
            str(repo_root / "tools" / "scripts" / "physical_device_boundary_merge.py"),
            "--output",
            args.manifest_output,
            *resolved_inputs,
        ],
    )
    steps.append(merge_step)
    proof_step = run_step(
        "physical-device-boundary-proof",
        [
            sys.executable,
            str(repo_root / "tools" / "scripts" / "physical_device_boundary_proof.py"),
            "--manifest",
            args.manifest_output,
            "--output",
            args.proof_output,
            "--write-template",
        ],
    )
    steps.append(proof_step)
    proof = read_json(Path(args.proof_output))
    summary = {
        "schemaVersion": 1,
        "status": "pass" if proof_step["ok"] else "fail",
        "ok": proof_step["ok"],
        "inputs": args.inputs,
        "resolvedManifests": resolved_inputs,
        "skippedMissingInputs": skipped_missing_inputs,
        "manifest": args.manifest_output,
        "proof": args.proof_output,
        "proofSummary": summarize_proof(proof),
        "steps": steps,
    }
    summary_path = Path(args.summary_output)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"physical-device boundary finalize status: {summary['status']}")
    print(f"physical-device boundary finalize artifact: {summary_path}")
    print(f"physical-device boundary manifest: {args.manifest_output}")
    print(f"physical-device boundary proof: {args.proof_output}")
    return 0 if summary["ok"] else 1


def run_step(name: str, command: list[str]) -> dict[str, Any]:
    result = subprocess.run(command, text=True, capture_output=True)
    return {
        "name": name,
        "ok": result.returncode == 0,
        "exitCode": result.returncode,
        "command": shlex.join(command),
        "stdout": result.stdout,
        "stderr": result.stderr,
    }


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def summarize_proof(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        return {"status": "missing", "passedCells": [], "failedCells": []}
    cells = payload.get("cells") if isinstance(payload.get("cells"), list) else []
    return {
        "status": str(payload.get("status") or "unknown"),
        "manifestEvidenceSince": payload.get("manifestEvidenceSince"),
        "sourceEvidenceWindows": payload.get("sourceEvidenceWindows")
        if isinstance(payload.get("sourceEvidenceWindows"), list)
        else [],
        "passedCells": [
            str(cell.get("name") or "")
            for cell in cells
            if isinstance(cell, dict) and cell.get("status") == "pass"
        ],
        "failedCells": [
            {
                "name": str(cell.get("name") or ""),
                "reason": str(cell.get("reason") or ""),
            }
            for cell in cells
            if isinstance(cell, dict) and cell.get("status") != "pass"
        ],
    }


if __name__ == "__main__":
    raise SystemExit(main())
