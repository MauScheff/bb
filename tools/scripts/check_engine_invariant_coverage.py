#!/usr/bin/env python3
"""Check that active engine invariants have executable coverage references."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REGISTRY = REPO_ROOT / "invariants" / "registry.json"
DEFAULT_PROOF_ROOTS = [
    REPO_ROOT / "Packages" / "TurboEngine" / "Tests",
    REPO_ROOT / "Packages" / "TurboEngine" / "Sources" / "TurboEngineSimulation",
    REPO_ROOT / "Packages" / "TurboEngine" / "Fixtures",
    REPO_ROOT / "TurboTests",
]
DEFAULT_DETECTOR_ROOTS = [
    REPO_ROOT / "Packages" / "TurboEngine" / "Sources" / "TurboEngine",
    REPO_ROOT / "Packages" / "TurboEngine" / "Sources" / "TurboEngineSimulation",
]
SOURCE_SUFFIXES = {".swift", ".json"}
ENGINE_ID_LITERAL_RE = re.compile(r'"(engine\.[a-z0-9_.-]+)"')


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument(
        "--proof-root",
        action="append",
        type=Path,
        default=[],
        help="Additional root to scan for proof references.",
    )
    return parser.parse_args()


def load_active_engine_invariants(path: Path) -> set[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return {
        entry["id"]
        for entry in payload.get("invariants", [])
        if entry.get("status") == "active" and str(entry.get("id", "")).startswith("engine.")
    }


def iter_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        if root.is_file():
            files.append(root)
            continue
        for path in root.rglob("*"):
            if path.is_file() and path.suffix in SOURCE_SUFFIXES:
                files.append(path)
    return files


def scan_engine_ids(roots: list[Path]) -> dict[str, list[str]]:
    references: dict[str, list[str]] = {}
    for path in iter_files(roots):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(lines, start=1):
            for match in ENGINE_ID_LITERAL_RE.finditer(line):
                invariant_id = match.group(1)
                relative = path.relative_to(REPO_ROOT)
                references.setdefault(invariant_id, []).append(f"{relative}:{line_number}")
    return references


def main() -> int:
    args = parse_args()
    registered = load_active_engine_invariants(args.registry)
    proof_roots = DEFAULT_PROOF_ROOTS + [path if path.is_absolute() else REPO_ROOT / path for path in args.proof_root]
    proof_references = scan_engine_ids(proof_roots)
    detector_references = scan_engine_ids(DEFAULT_DETECTOR_ROOTS)

    missing_proofs = sorted(registered - set(proof_references))
    unknown_detector_ids = sorted(set(detector_references) - registered)
    unknown_proof_ids = sorted(set(proof_references) - registered)

    if missing_proofs or unknown_detector_ids or unknown_proof_ids:
        if missing_proofs:
            print("Missing proof coverage:", file=sys.stderr)
            for invariant_id in missing_proofs:
                print(f"  - {invariant_id}", file=sys.stderr)
        if unknown_detector_ids:
            print("Detector references missing from registry:", file=sys.stderr)
            for invariant_id in unknown_detector_ids:
                print(f"  - {invariant_id}: {detector_references[invariant_id][0]}", file=sys.stderr)
        if unknown_proof_ids:
            print("Proof references missing from registry:", file=sys.stderr)
            for invariant_id in unknown_proof_ids:
                print(f"  - {invariant_id}: {proof_references[invariant_id][0]}", file=sys.stderr)
        return 1

    print(f"engine invariant coverage ok: {len(registered)} active invariants")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
