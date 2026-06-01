#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import physical_device_boundary_proof


ARTIFACT_KEYS = {
    "mergedDiagnosticsJson",
    "mergedDiagnosticsText",
    "diagnostics",
    "diagnosticsText",
    "artifact",
    "path",
}

EVIDENCE_RULES: dict[str, dict[str, list[list[str]]]] = {
    "foreground-ptt-audio": {
        "both devices converge to ready": [
            ["selectedConversationPhase", "ready"],
            ["selectedConversationStatus", "Ready"],
            ["receiver-ready", "Connected"],
        ],
        "sender reaches PTT audio session activated": [
            [
                "Requesting Apple system transmit in parallel with backend lease",
                "Backend transmit lease granted",
                "System transmit began",
                "PTT audio session activated",
            ],
            ["System transmit began", "PTT audio session activated"],
        ],
        "receiver reaches receiving and heard first transmit": [
            ["Signal received", "type=transmit-start", "Audio chunk received", "Playback buffer scheduled"],
            ["selectedConversationPhase", "receiving", "Audio chunk received", "Playback buffer scheduled"],
        ],
        "release returns both devices to ready": [
            ["transmit-stop", "selectedConversationPhase", "ready"],
            ["transmit-stop", "selectedConversationStatus", "Ready"],
            ["released transmit", "selectedConversationPhase", "ready"],
        ],
    },
    "lockscreen-apns-wake": {
        "wake-capable target exists before request": [
            ["wake-capable"],
            ["wakeReady"],
            ["wakeReadiness", "wake-capable"],
        ],
        "incoming push received on locked/background receiver": [
            ["Incoming PTT push received", "background"],
            ["Incoming PTT push received", "locked"],
            ["Incoming PTT push received", "protected-data-will-become-unavailable"],
        ],
        "PTT audio session activated after wake": [
            ["Incoming PTT push received", "PTT audio session activated"],
            ["wake", "PTT audio session activated"],
            ["PTT audio session activated", "applicationState=UIApplicationState(rawValue: 2)", "pendingWakeChannelUUID"],
            ["Wake receive timing", "incomingWakeActivationState=systemActivated", "stage=system-audio-activation-observed"],
        ],
        "lock-screen playback verified": [
            ["systemActivated", "Playback buffer scheduled"],
            ["wake", "Audio chunk received", "Playback buffer scheduled"],
            ["Incoming PTT push received", "Playback buffer scheduled"],
            ["Wake receive timing", "incomingWakeActivationState=systemActivated", "stage=first-playback-buffer-scheduled"],
            ["Wake receive timing", "incomingWakeActivationState=systemActivated", "stage=playback-node-started"],
            ["Sent first audio playback ACK", "incomingTransport=relay-websocket"],
        ],
    },
    "direct-quic-media": {
        "fresh Direct QUIC identity projected": [
            ["Direct QUIC", "identity"],
            ["direct-quic", "identity"],
            ["directQuic", "identity"],
        ],
        "media routed over Direct QUIC": [
            ["transport=direct-quic"],
            ["source=direct-quic"],
            ["direct-quic-data-channel"],
        ],
        "packet audio received and scheduled": [
            ["Audio chunk received", "transport=direct-quic", "Playback buffer scheduled"],
            ["Audio chunk received", "source=direct-quic", "Playback buffer scheduled"],
        ],
    },
    "fallback-relay-audio": {
        "fallback relay path selected": [
            ["Media relay TCP ordered fallback connected"],
            ["transport=media-relay-tcp"],
            ["transport=relay-websocket"],
            ["media-relay-packet"],
        ],
        "capture starts only after backend lease and Apple activation": [
            ["Backend transmit lease granted", "PTT audio session activated", "Starting audio capture"],
            ["Backend transmit lease granted", "System transmit began", "Starting audio capture"],
        ],
        "receiver playback scheduled through fallback path": [
            ["Audio chunk received", "transport=media-relay-tcp", "Playback buffer scheduled"],
            ["Audio chunk received", "transport=relay-websocket", "Playback buffer scheduled"],
            ["Audio chunk received", "media-relay-packet", "Playback buffer scheduled"],
        ],
    },
}

CONTEXT_RULES = physical_device_boundary_proof.REQUIRED_CELL_CONTEXTS
TIMESTAMP_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Derive a physical-device boundary manifest from merged/copied diagnostics "
            "artifacts. The generated manifest only marks cells passing when all required "
            "evidence anchors are present and at least two device ids are known."
        )
    )
    parser.add_argument(
        "artifacts",
        nargs="*",
        help="Diagnostics artifacts to scan. JSON and text files are both accepted.",
    )
    parser.add_argument(
        "--artifact",
        action="append",
        default=[],
        help="Additional diagnostics artifact to scan.",
    )
    parser.add_argument(
        "--device",
        action="append",
        default=[],
        help="Physical device id/name/UDID. Repeat for sender and receiver. When omitted, merged diagnostics report deviceIds are used when available.",
    )
    parser.add_argument(
        "--output",
        default="/tmp/turbo-physical-device-boundaries-manifest.json",
        help="Manifest path to write.",
    )
    parser.add_argument(
        "--since",
        default="",
        help="Only use timestamped diagnostic lines at or after this UTC ISO-8601 instant for evidence.",
    )
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="Exit nonzero unless every required physical-device cell can be generated as pass.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    since = parse_utc_timestamp(args.since) if args.since.strip() else None
    artifact_paths = normalized_paths([*args.artifact, *args.artifacts])
    artifacts = [read_artifact(path, since=since) for path in artifact_paths]
    devices = normalized_devices(args.device) or devices_from_artifacts(artifacts)
    manifest = build_manifest(artifacts, devices, since=args.since.strip())
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    cells = manifest["cells"]
    passing = [cell["name"] for cell in cells if cell.get("status") == "pass"]
    failing = [cell["name"] for cell in cells if cell.get("status") != "pass"]
    print(f"physical-device boundary manifest: {output}")
    print(f"passing cells: {', '.join(passing) if passing else '(none)'}")
    print(f"incomplete cells: {', '.join(failing) if failing else '(none)'}")
    return 1 if args.require_complete and failing else 0


def build_manifest(
    artifacts: list[dict[str, Any]],
    devices: list[str],
    *,
    since: str = "",
) -> dict[str, Any]:
    artifact_paths = [artifact["path"] for artifact in artifacts]
    cells = [
        build_cell(cell_name, artifacts, artifact_paths, devices)
        for cell_name in physical_device_boundary_proof.REQUIRED_CELLS
    ]
    return {
        "schemaVersion": 1,
        "createdAt": utc_now(),
        "evidenceSince": since,
        "devices": devices,
        "artifacts": artifact_paths,
        "cells": cells,
    }


def build_cell(
    name: str,
    artifacts: list[dict[str, Any]],
    artifact_paths: list[str],
    devices: list[str],
) -> dict[str, Any]:
    required_checks = physical_device_boundary_proof.REQUIRED_CELL_CHECKS[name]
    evidence = {
        check: evidence_entries(check, artifacts, EVIDENCE_RULES[name][check])
        for check in required_checks
    }
    context = {
        context_name: evidence_entries(context_name, artifacts, candidates)
        for context_name, candidates in CONTEXT_RULES.get(name, {}).items()
    }
    complete = (
        len(set(devices)) >= 2
        and bool(artifact_paths)
        and all(evidence[check] for check in required_checks)
        and all(context[context_name] for context_name in context)
    )
    return {
        "name": name,
        "status": "pass" if complete else "pending",
        "ok": complete,
        "devices": devices,
        "artifacts": artifact_paths,
        "checks": required_checks,
        "evidence": evidence,
        "context": context,
    }


def evidence_entries(
    check: str,
    artifacts: list[dict[str, Any]],
    candidates: list[list[str]],
) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for artifact in artifacts:
        for anchors in candidates:
            if anchors_present(artifact["text"], anchors):
                entries.append(
                    {
                        "artifact": artifact["path"],
                        "anchors": anchors,
                    }
                )
                break
    return entries


def anchors_present(text: str, anchors: list[str]) -> bool:
    return all(anchor in text for anchor in anchors)


def read_artifact(path: str, *, since: datetime | None = None) -> dict[str, Any]:
    path_obj = Path(path)
    text = path_obj.read_text(encoding="utf-8", errors="replace")
    return {
        "path": str(path_obj),
        "text": filter_text_since(text, since),
        "json": parse_json(text),
    }


def filter_text_since(text: str, since: datetime | None) -> str:
    if since is None:
        return text
    kept: list[str] = []
    for line in text.splitlines():
        timestamp = line_timestamp(line)
        if timestamp is not None and timestamp >= since:
            kept.append(line)
    return "\n".join(kept)


def line_timestamp(line: str) -> datetime | None:
    match = TIMESTAMP_RE.search(line)
    if not match:
        return None
    return parse_utc_timestamp(match.group(0))


def parse_utc_timestamp(value: str) -> datetime:
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def parse_json(text: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def devices_from_artifacts(artifacts: list[dict[str, Any]]) -> list[str]:
    devices: list[str] = []
    for artifact in artifacts:
        collect_devices(artifact.get("json"), devices)
    return dedupe(devices)


def collect_devices(value: Any, devices: list[str]) -> None:
    if isinstance(value, dict):
        device_id = value.get("deviceId")
        if isinstance(device_id, str) and device_id.strip():
            devices.append(device_id.strip())
        device = value.get("device")
        if isinstance(device, dict):
            for key in ("udid", "name", "devicectlIdentifier"):
                device_value = device.get(key)
                if isinstance(device_value, str) and device_value.strip():
                    devices.append(device_value.strip())
                    break
        for key, child in value.items():
            if key in ARTIFACT_KEYS and isinstance(child, str):
                continue
            collect_devices(child, devices)
    elif isinstance(value, list):
        for item in value:
            collect_devices(item, devices)


def normalized_paths(paths: list[str]) -> list[str]:
    return dedupe([str(Path(path)) for path in paths if path and path.strip()])


def normalized_devices(devices: list[str]) -> list[str]:
    return dedupe([device.strip() for device in devices if device and device.strip()])


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
