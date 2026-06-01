#!/usr/bin/env python3
"""Extract a replayable EngineTrace from diagnostics or trace JSON."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SECTION_RE = re.compile(
    r"^(STATE SNAPSHOT|STRUCTURED DIAGNOSTICS|STATE TIMELINE|INVARIANT VIOLATIONS|DIAGNOSTICS)$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Diagnostics transcript, merged JSON, or EngineTrace JSON.")
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        help="Write the extracted EngineTrace JSON to this path. Defaults to stdout.",
    )
    return parser.parse_args()


def looks_like_trace(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and value.get("schemaVersion") == 1
        and looks_like_device_id(value.get("localDeviceID"))
        and isinstance(value.get("initialState"), dict)
        and isinstance(value.get("steps"), list)
    )


def looks_like_device_id(value: Any) -> bool:
    return (
        isinstance(value, str)
        or (
            isinstance(value, dict)
            and isinstance(value.get("rawValue"), str)
        )
    )


def find_engine_trace(value: Any) -> dict[str, Any] | None:
    if looks_like_trace(value):
        return value
    if isinstance(value, dict):
        trace = value.get("engineTrace")
        if looks_like_trace(trace):
            return trace
        for child in value.values():
            found = find_engine_trace(child)
            if found is not None:
                return found
    if isinstance(value, list):
        for child in value:
            found = find_engine_trace(child)
            if found is not None:
                return found
    return None


def structured_diagnostics_section(text: str) -> str | None:
    lines = text.splitlines()
    collecting = False
    collected: list[str] = []
    for line in lines:
        if SECTION_RE.match(line):
            if line == "STRUCTURED DIAGNOSTICS":
                collecting = True
                collected = []
                continue
            if collecting:
                break
        elif collecting:
            collected.append(line)
    section = "\n".join(collected).strip()
    return section or None


def load_artifact(path: Path) -> Any:
    text = path.read_text(encoding="utf-8")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        section = structured_diagnostics_section(text)
        if section is None:
            raise ValueError("artifact is not JSON and has no STRUCTURED DIAGNOSTICS section")
        return json.loads(section)


def main() -> int:
    args = parse_args()
    artifact = load_artifact(args.source)
    trace = find_engine_trace(artifact)
    if trace is None:
        print("no engineTrace found", file=sys.stderr)
        return 1

    encoded = json.dumps(trace, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
