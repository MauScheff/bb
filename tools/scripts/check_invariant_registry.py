#!/usr/bin/env python3
"""Validate Turbo's checked-in invariant registry.

The checker intentionally scans known invariant emission/assertion shapes
instead of every dotted string. The repo contains many non-invariant dotted
values: bundle IDs, hostnames, filenames, telemetry event names, and asset
names. Registry enforcement should catch invariant drift without making those
ordinary strings part of the invariant contract.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REGISTRY = REPO_ROOT / "shared" / "invariants" / "registry.json"

ALLOWED_SCOPES = {"local", "backend", "pair", "convergence", "remote", "distributed"}
ALLOWED_OWNERS = {"app", "backend", "merged diagnostics", "Apple boundary", "mixed"}
ALLOWED_REPAIR_POLICIES = {"none", "app repair", "backend repair", "manual boundary"}
ALLOWED_STATUSES = {"planned", "active", "deprecated"}

INVARIANT_ID_RE = re.compile(r"^[a-z][a-z0-9-]*\.[a-z0-9_.-]+$")

SCAN_ROOTS = [
    "client/ios/Turbo",
    "client/ios/TurboTests",
    "client/ios/TurboUITests",
    "shared/contracts",
    "tools/scripts",
    "backend/scripts",
    "shared/scenarios",
    "docs/reliability/INVARIANTS.md",
    "docs/reliability/STATE_MACHINE_TESTING.md",
    "docs/reliability/SELF_HEALING.md",
    "TOOLING.md",
]

SCAN_SUFFIXES = {".swift", ".py", ".json", ".md"}

REFERENCE_PATTERNS = [
    ("swift-argument", re.compile(r"\binvariantID\s*:\s*\"(?P<id>[^\"]+)\"")),
    ("swift-equality", re.compile(r"\binvariantID\s*==\s*\"(?P<id>[^\"]+)\"")),
    ("json-invariantID", re.compile(r"\"invariantID\"\s*:\s*\"(?P<id>[^\"]+)\"")),
    ("json-invariantId", re.compile(r"\"invariantId\"\s*:\s*\"(?P<id>[^\"]+)\"")),
    ("python-keyword", re.compile(r"\binvariant_id\s*=\s*\"(?P<id>[^\"]+)\"")),
]

JSON_INVARIANT_KEYS = {"invariantID", "invariantId"}
JSON_SCENARIO_INVARIANT_LIST_KEYS = {
    "expectInvariant",
    "eventuallyNoInvariant",
    "allowInvariantDuringStep",
}

REQUIRED_FIELDS = [
    "id",
    "scope",
    "owner",
    "authoritativeSeam",
    "predicate",
    "evidenceFields",
    "detectors",
    "regressions",
    "repairPolicy",
    "alertPolicy",
    "status",
]


@dataclass(frozen=True)
class InvariantReference:
    invariant_id: str
    path: Path
    line_number: int
    kind: str

    def display(self) -> str:
        rel = self.path.relative_to(REPO_ROOT)
        return f"{rel}:{self.line_number} ({self.kind})"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--registry",
        type=Path,
        default=DEFAULT_REGISTRY,
        help="Path to invariants registry JSON.",
    )
    parser.add_argument(
        "--no-source-scan",
        action="store_true",
        help="Only validate registry shape; do not scan source references.",
    )
    return parser.parse_args()


def load_registry(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError:
        raise ValueError(f"registry not found: {path}") from None
    except json.JSONDecodeError as error:
        raise ValueError(f"registry is not valid JSON: {error}") from None

    if not isinstance(payload, dict):
        raise ValueError("registry root must be a JSON object")
    if payload.get("schemaVersion") != 1:
        raise ValueError("registry schemaVersion must be 1")
    if not isinstance(payload.get("invariants"), list):
        raise ValueError("registry invariants must be a list")
    return payload


def validate_registry(payload: dict) -> tuple[dict[str, dict], list[str]]:
    errors: list[str] = []
    entries_by_id: dict[str, dict] = {}

    for index, entry in enumerate(payload["invariants"]):
        label = f"invariants[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{label}: entry must be an object")
            continue

        invariant_id = entry.get("id")
        if not isinstance(invariant_id, str) or not invariant_id:
            errors.append(f"{label}: id must be a non-empty string")
            continue
        label = invariant_id

        if invariant_id in entries_by_id:
            errors.append(f"{label}: duplicate invariant id")
        entries_by_id[invariant_id] = entry

        if not INVARIANT_ID_RE.fullmatch(invariant_id):
            errors.append(f"{label}: id must match {INVARIANT_ID_RE.pattern}")

        for field in REQUIRED_FIELDS:
            if field not in entry:
                errors.append(f"{label}: missing required field {field}")

        validate_string_enum(errors, entry, label, "scope", ALLOWED_SCOPES)
        validate_string_enum(errors, entry, label, "owner", ALLOWED_OWNERS)
        validate_string_enum(errors, entry, label, "repairPolicy", ALLOWED_REPAIR_POLICIES)
        validate_string_enum(errors, entry, label, "status", ALLOWED_STATUSES)

        if entry.get("repairPolicy") in {"app repair", "backend repair"}:
            repair_action = entry.get("repairAction")
            if not isinstance(repair_action, str) or not repair_action.strip():
                errors.append(
                    f"{label}: {entry.get('repairPolicy')} invariant must describe repairAction"
                )
            if not entry.get("regressions"):
                errors.append(
                    f"{label}: {entry.get('repairPolicy')} invariant must list a repair regression"
                )

        for field in ["authoritativeSeam", "predicate", "alertPolicy"]:
            if not isinstance(entry.get(field), str) or not entry.get(field, "").strip():
                errors.append(f"{label}: {field} must be a non-empty string")

        for field in ["evidenceFields", "detectors", "regressions"]:
            validate_string_list(errors, entry, label, field)

        status = entry.get("status")
        if status == "active":
            if not entry.get("detectors"):
                errors.append(f"{label}: active invariant must list at least one detector")
            has_regression = bool(entry.get("regressions"))
            has_exception = bool(str(entry.get("regressionException", "")).strip())
            if not has_regression and not has_exception:
                errors.append(
                    f"{label}: active invariant must list a regression or regressionException"
                )

        validate_referenced_paths(errors, entry, label, "detectors")
        validate_referenced_paths(errors, entry, label, "regressions")

    return entries_by_id, errors


def validate_string_enum(
    errors: list[str],
    entry: dict,
    label: str,
    field: str,
    allowed: set[str],
) -> None:
    value = entry.get(field)
    if not isinstance(value, str) or value not in allowed:
        allowed_values = ", ".join(sorted(allowed))
        errors.append(f"{label}: {field} must be one of: {allowed_values}")


def validate_string_list(errors: list[str], entry: dict, label: str, field: str) -> None:
    value = entry.get(field)
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        errors.append(f"{label}: {field} must be a list of non-empty strings")


def validate_referenced_paths(errors: list[str], entry: dict, label: str, field: str) -> None:
    value = entry.get(field)
    if not isinstance(value, list):
        return
    for raw_reference in value:
        if not isinstance(raw_reference, str):
            continue
        path_text = raw_reference.split(":", 1)[0]
        if not path_text.endswith((".swift", ".py", ".json", ".md", "justfile")):
            continue
        if resolve_reference_path(path_text) is None:
            errors.append(f"{label}: {field} path does not exist: {raw_reference}")


def resolve_reference_path(path_text: str) -> Path | None:
    candidates = [REPO_ROOT / path_text]
    legacy_prefixes = {
        "Turbo/": "client/ios/Turbo/",
        "TurboTests/": "client/ios/TurboTests/",
        "TurboUITests/": "client/ios/TurboUITests/",
        "contracts/": "shared/contracts/",
        "invariants/": "shared/invariants/",
        "scenarios/": "shared/scenarios/",
        "scripts/": "tools/scripts/",
        "INVARIANTS.md": "docs/reliability/INVARIANTS.md",
        "STATE_MACHINE_TESTING.md": "docs/reliability/STATE_MACHINE_TESTING.md",
        "SELF_HEALING.md": "docs/reliability/SELF_HEALING.md",
    }
    for old, new in legacy_prefixes.items():
        if path_text == old.rstrip("/") or path_text.startswith(old):
            candidates.append(REPO_ROOT / path_text.replace(old, new, 1))
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def iter_scan_files() -> Iterable[Path]:
    for root in SCAN_ROOTS:
        path = REPO_ROOT / root
        if not path.exists():
            continue
        if path.is_file():
            if should_scan(path):
                yield path
            continue
        for candidate in path.rglob("*"):
            if candidate.is_file() and should_scan(candidate):
                yield candidate


def should_scan(path: Path) -> bool:
    parts = set(path.relative_to(REPO_ROOT).parts)
    if ".git" in parts or ".scenario-diagnostics" in parts:
        return False
    if path.name == "registry.json":
        return False
    return path.suffix in SCAN_SUFFIXES or path.name == "justfile"


def scan_references() -> list[InvariantReference]:
    references: list[InvariantReference] = []
    for path in iter_scan_files():
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            for kind, pattern in REFERENCE_PATTERNS:
                for match in pattern.finditer(line):
                    invariant_id = match.group("id")
                    if INVARIANT_ID_RE.fullmatch(invariant_id):
                        references.append(
                            InvariantReference(
                                invariant_id=invariant_id,
                                path=path,
                                line_number=line_number,
                                kind=kind,
                            )
                        )
        if path.suffix == ".json":
            references.extend(scan_json_references(path, text))
    return references


def scan_json_references(path: Path, text: str) -> list[InvariantReference]:
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return []

    references: list[InvariantReference] = []
    for invariant_id, kind in iter_json_invariant_ids(payload):
        if INVARIANT_ID_RE.fullmatch(invariant_id):
            references.append(
                InvariantReference(
                    invariant_id=invariant_id,
                    path=path,
                    line_number=line_number_for_json_value(text, invariant_id),
                    kind=kind,
                )
            )
    return references


def iter_json_invariant_ids(value: object, parent_key: str | None = None) -> Iterable[tuple[str, str]]:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in JSON_INVARIANT_KEYS and isinstance(child, str):
                yield child, f"json-{key}"
            elif key in JSON_SCENARIO_INVARIANT_LIST_KEYS and isinstance(child, list):
                for item in child:
                    if isinstance(item, str):
                        yield item, f"json-{key}"
            else:
                yield from iter_json_invariant_ids(child, key)
    elif isinstance(value, list):
        for child in value:
            yield from iter_json_invariant_ids(child, parent_key)


def line_number_for_json_value(text: str, value: str) -> int:
    encoded = json.dumps(value)
    index = text.find(encoded)
    if index < 0:
        return 1
    return text[:index].count("\n") + 1


def validate_source_references(
    entries_by_id: dict[str, dict],
    references: list[InvariantReference],
) -> list[str]:
    errors: list[str] = []
    registry_ids = set(entries_by_id)

    refs_by_id: dict[str, list[InvariantReference]] = {}
    for reference in references:
        refs_by_id.setdefault(reference.invariant_id, []).append(reference)

    for invariant_id in sorted(set(refs_by_id) - registry_ids):
        first_reference = refs_by_id[invariant_id][0]
        errors.append(
            f"{invariant_id}: referenced at {first_reference.display()} but not registered"
        )

    deprecated_references = sorted(
        invariant_id
        for invariant_id, entry in entries_by_id.items()
        if entry.get("status") == "deprecated" and invariant_id in refs_by_id
    )
    for invariant_id in deprecated_references:
        first_reference = refs_by_id[invariant_id][0]
        errors.append(
            f"{invariant_id}: deprecated invariant still referenced at {first_reference.display()}"
        )

    return errors


def main() -> int:
    args = parse_args()

    try:
        payload = load_registry(args.registry)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    entries_by_id, errors = validate_registry(payload)

    references: list[InvariantReference] = []
    if not args.no_source_scan:
        references = scan_references()
        errors.extend(validate_source_references(entries_by_id, references))

    if errors:
        print("Invariant registry check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    active_count = sum(1 for entry in entries_by_id.values() if entry.get("status") == "active")
    print(
        "Invariant registry check passed: "
        f"{len(entries_by_id)} registered, {active_count} active, "
        f"{len({reference.invariant_id for reference in references})} referenced."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
