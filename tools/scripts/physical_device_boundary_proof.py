#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REQUIRED_CELLS = [
    "foreground-ptt-audio",
    "lockscreen-apns-wake",
    "direct-quic-media",
    "fallback-relay-audio",
]

REQUIRED_CELL_CHECKS = {
    "foreground-ptt-audio": [
        "both devices converge to ready",
        "sender reaches PTT audio session activated",
        "receiver reaches receiving and heard first transmit",
        "release returns both devices to ready",
    ],
    "lockscreen-apns-wake": [
        "wake-capable target exists before request",
        "incoming push received on locked/background receiver",
        "PTT audio session activated after wake",
        "lock-screen playback verified",
    ],
    "direct-quic-media": [
        "fresh Direct QUIC identity projected",
        "media routed over Direct QUIC",
        "packet audio received and scheduled",
    ],
    "fallback-relay-audio": [
        "fallback relay path selected",
        "capture starts only after backend lease and Apple activation",
        "receiver playback scheduled through fallback path",
    ],
}

REQUIRED_CELL_CONTEXTS = {
    "direct-quic-media": {
        "Direct QUIC run configuration active": [
            ["Physical boundary launch profile", "transport=direct-quic"],
            ["directQuicIsActive=true"],
            ["directQuicActive=true"],
            ["transport=direct-quic"],
        ],
    },
    "fallback-relay-audio": {
        "fallback relay run configuration active": [
            ["Physical boundary launch profile", "transport=media-relay-forced"],
            ["mediaRelayForced=true"],
            ["transport=media-relay-forced"],
            ["transport=relay-websocket"],
            ["transport=media-relay-packet"],
            ["transport=media-relay-tcp"],
        ],
    },
    "lockscreen-apns-wake": {
        "receiver entered background or locked": [
            ["Application entered background"],
            ["protected-data-will-become-unavailable"],
            ["locked"],
        ],
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate physical-device PTT/audio/QUIC/APNs cutover evidence."
    )
    parser.add_argument(
        "--manifest",
        default="/tmp/turbo-physical-device-boundaries-manifest.json",
        help="JSON manifest describing physical-device proof cells.",
    )
    parser.add_argument(
        "--output",
        default="/tmp/turbo-physical-device-boundaries.json",
        help="Validated physical-device boundary proof artifact.",
    )
    parser.add_argument(
        "--write-template",
        action="store_true",
        help="Write a template manifest when the manifest path does not exist.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest)
    if args.write_template and not manifest_path.exists():
        write_template(manifest_path)

    manifest = read_json(manifest_path)
    cell_results = validate_cells(manifest, manifest_path)
    ok = all(cell["status"] == "pass" for cell in cell_results)
    summary = {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "status": "pass" if ok else "fail",
        "ok": ok,
        "manifest": str(manifest_path),
        "manifestEvidenceSince": manifest.get("evidenceSince") if isinstance(manifest, dict) else None,
        "sourceEvidenceWindows": manifest.get("sourceEvidenceWindows", []) if isinstance(manifest, dict) else [],
        "requiredCells": REQUIRED_CELLS,
        "devices": manifest.get("devices", []) if isinstance(manifest, dict) else [],
        "cells": cell_results,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"physical-device boundary proof status: {summary['status']}")
    print(f"physical-device boundary proof artifact: {output}")
    return 0 if ok else 1


def validate_cells(manifest: dict[str, Any] | None, manifest_path: Path) -> list[dict[str, Any]]:
    if manifest is None:
        return [
            {
                "name": cell,
                "status": "missing",
                "ok": False,
                "reason": f"manifest not found or invalid: {manifest_path}",
            }
            for cell in REQUIRED_CELLS
        ]

    raw_cells = manifest.get("cells")
    cells = raw_cells if isinstance(raw_cells, list) else []
    by_name = {
        str(cell.get("name")): cell
        for cell in cells
        if isinstance(cell, dict) and cell.get("name")
    }
    return [validate_cell(name, by_name.get(name)) for name in REQUIRED_CELLS]


def validate_cell(name: str, cell: dict[str, Any] | None) -> dict[str, Any]:
    if cell is None:
        return {
            "name": name,
            "status": "missing",
            "ok": False,
            "reason": "required physical-device cell absent from manifest",
        }

    status = str(cell.get("status") or "").lower()
    ok = cell.get("ok") is True or status in {"pass", "ok"}
    artifact_paths = normalized_artifact_paths(cell.get("artifacts"))
    artifact_results = [
        {
            "path": path,
            "exists": Path(path).exists(),
            "placeholder": is_placeholder(path),
        }
        for path in artifact_paths
    ]
    artifacts_ok = bool(artifact_results) and all(
        item["exists"] and not item["placeholder"] for item in artifact_results
    )
    devices = cell.get("devices", [])
    device_ids = [str(device) for device in devices] if isinstance(devices, list) else []
    devices_ok = (
        len(device_ids) >= 2
        and len(set(device_ids)) >= 2
        and all(not is_placeholder(device) for device in device_ids)
    )
    checks = cell.get("checks", [])
    check_texts = [str(check) for check in checks] if isinstance(checks, list) else []
    missing_checks = [
        required
        for required in REQUIRED_CELL_CHECKS[name]
        if required not in check_texts
    ]
    checks_ok = not missing_checks
    evidence_results = validate_check_evidence(cell.get("evidence"), REQUIRED_CELL_CHECKS[name])
    evidence_ok = all(item["ok"] for item in evidence_results)
    context_results = validate_context_evidence(cell.get("context"), REQUIRED_CELL_CONTEXTS.get(name, {}))
    context_ok = all(item["ok"] for item in context_results)
    passed = ok and artifacts_ok and devices_ok and checks_ok and evidence_ok and context_ok

    result = {
        "name": name,
        "status": "pass" if passed else "fail",
        "ok": passed,
        "manifestStatus": cell.get("status"),
        "manifestOk": cell.get("ok"),
        "devices": devices,
        "checks": checks,
        "missingChecks": missing_checks,
        "evidence": evidence_results,
        "context": context_results,
        "artifacts": artifact_results,
        "sourceManifests": cell.get("sourceManifests") if isinstance(cell.get("sourceManifests"), list) else [],
        "sourceEvidenceSince": cell.get("sourceEvidenceSince"),
    }
    if not passed:
        result["reason"] = failure_reason(
            ok,
            artifacts_ok,
            devices_ok,
            checks_ok,
            evidence_ok,
            context_ok,
            device_ids,
            artifact_paths,
            missing_checks,
            evidence_results,
            context_results,
        )
    return result


def validate_context_evidence(
    raw: Any,
    required_contexts: dict[str, list[list[str]]],
) -> list[dict[str, Any]]:
    context = raw if isinstance(raw, dict) else {}
    return [
        validate_single_check_evidence(context_name, context.get(context_name))
        for context_name in required_contexts
    ]


def validate_check_evidence(raw: Any, required_checks: list[str]) -> list[dict[str, Any]]:
    evidence = raw if isinstance(raw, dict) else {}
    return [
        validate_single_check_evidence(check, evidence.get(check))
        for check in required_checks
    ]


def validate_single_check_evidence(check: str, raw: Any) -> dict[str, Any]:
    entries = raw if isinstance(raw, list) else [raw] if isinstance(raw, dict) else []
    entry_results = [validate_evidence_entry(entry) for entry in entries]
    ok = bool(entry_results) and any(entry["ok"] for entry in entry_results)
    result = {
        "check": check,
        "ok": ok,
        "entries": entry_results,
    }
    if not ok:
        result["reason"] = "no evidence entry with all required anchors present"
    return result


def validate_evidence_entry(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return {
            "ok": False,
            "reason": "evidence entry must be an object",
        }
    path = str(raw.get("artifact") or "")
    anchors = raw.get("anchors")
    anchor_texts = [str(anchor) for anchor in anchors] if isinstance(anchors, list) else []
    path_obj = Path(path)
    if is_placeholder(path):
        return {
            "ok": False,
            "artifact": path,
            "anchors": anchor_texts,
            "reason": "artifact path is a placeholder",
        }
    if not path_obj.exists():
        return {
            "ok": False,
            "artifact": path,
            "anchors": anchor_texts,
            "reason": "artifact does not exist",
        }
    if not anchor_texts:
        return {
            "ok": False,
            "artifact": path,
            "anchors": anchor_texts,
            "reason": "anchors are required",
        }
    try:
        contents = path_obj.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        return {
            "ok": False,
            "artifact": path,
            "anchors": anchor_texts,
            "reason": f"artifact could not be read: {error}",
        }
    missing_anchors = [anchor for anchor in anchor_texts if anchor not in contents]
    return {
        "ok": not missing_anchors,
        "artifact": path,
        "anchors": anchor_texts,
        "missingAnchors": missing_anchors,
    }


def normalized_artifact_paths(raw: Any) -> list[str]:
    if not isinstance(raw, list):
        return []
    return [str(item) for item in raw if str(item) and not str(item).isspace()]


def failure_reason(
    ok: bool,
    artifacts_ok: bool,
    devices_ok: bool,
    checks_ok: bool,
    evidence_ok: bool,
    context_ok: bool,
    devices: list[str],
    artifacts: list[str],
    missing_checks: list[str],
    evidence_results: list[dict[str, Any]],
    context_results: list[dict[str, Any]],
) -> str:
    missing = []
    if not ok:
        missing.append("cell status is not passing")
    if not artifacts_ok:
        if any(is_placeholder(path) for path in artifacts):
            missing.append("artifact paths contain placeholders")
        else:
            missing.append("no existing evidence artifacts listed")
    if not devices_ok:
        if any(is_placeholder(device) for device in devices):
            missing.append("device ids contain placeholders")
        else:
            missing.append("fewer than two distinct physical devices listed")
    if not checks_ok:
        missing.append(f"missing required checks: {missing_checks!r}")
    if not evidence_ok:
        missing_evidence = [
            item["check"]
            for item in evidence_results
            if item.get("ok") is not True
        ]
        missing.append(f"missing required evidence anchors: {missing_evidence!r}")
    if not context_ok:
        missing_context = [
            item["check"]
            for item in context_results
            if item.get("ok") is not True
        ]
        missing.append(f"missing required context anchors: {missing_context!r}")
    return "; ".join(missing)


def is_placeholder(value: str) -> bool:
    stripped = value.strip()
    return not stripped or "<" in stripped or ">" in stripped


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def write_template(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    merged = "/tmp/turbo-debug/<run>/merged-diagnostics.json"
    audio_corpus = "/tmp/turbo-debug/<run>/audio-incident-corpus.json"
    cells = [
        {
            "name": "foreground-ptt-audio",
            "status": "pending",
            "devices": ["<sender-device-id>", "<receiver-device-id>"],
            "artifacts": [
                merged,
                audio_corpus,
            ],
            "checks": [
                *REQUIRED_CELL_CHECKS["foreground-ptt-audio"],
            ],
            "evidence": evidence_template(
                REQUIRED_CELL_CHECKS["foreground-ptt-audio"],
                merged,
            ),
            "context": context_template("foreground-ptt-audio", merged),
        },
        {
            "name": "lockscreen-apns-wake",
            "status": "pending",
            "devices": ["<sender-device-id>", "<receiver-device-id>"],
            "artifacts": [merged],
            "checks": REQUIRED_CELL_CHECKS["lockscreen-apns-wake"],
            "evidence": evidence_template(
                REQUIRED_CELL_CHECKS["lockscreen-apns-wake"],
                merged,
            ),
            "context": context_template("lockscreen-apns-wake", merged),
        },
        {
            "name": "direct-quic-media",
            "status": "pending",
            "devices": ["<sender-device-id>", "<receiver-device-id>"],
            "artifacts": [merged],
            "checks": REQUIRED_CELL_CHECKS["direct-quic-media"],
            "evidence": evidence_template(
                REQUIRED_CELL_CHECKS["direct-quic-media"],
                merged,
            ),
            "context": context_template("direct-quic-media", merged),
        },
        {
            "name": "fallback-relay-audio",
            "status": "pending",
            "devices": ["<sender-device-id>", "<receiver-device-id>"],
            "artifacts": [merged],
            "checks": REQUIRED_CELL_CHECKS["fallback-relay-audio"],
            "evidence": evidence_template(
                REQUIRED_CELL_CHECKS["fallback-relay-audio"],
                merged,
            ),
            "context": context_template("fallback-relay-audio", merged),
        },
    ]
    payload = {
        "schemaVersion": 1,
        "createdAt": utc_now(),
        "devices": [],
        "cells": cells,
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def evidence_template(checks: list[str], artifact: str) -> dict[str, list[dict[str, Any]]]:
    return {
        check: [
            {
                "artifact": artifact,
                "anchors": ["<diagnostic text proving this check>"],
            }
        ]
        for check in checks
    }


def context_template(cell_name: str, artifact: str) -> dict[str, list[dict[str, Any]]]:
    return {
        context_name: [
            {
                "artifact": artifact,
                "anchors": ["<diagnostic text proving this cell context>"],
            }
        ]
        for context_name in REQUIRED_CELL_CONTEXTS.get(cell_name, {})
    }


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
