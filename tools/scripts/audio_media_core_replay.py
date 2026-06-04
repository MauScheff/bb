#!/usr/bin/env python3
"""Validate and summarize a VoiceMediaEventLog artifact."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()

    payload = json.loads(args.trace.read_text(encoding="utf-8"))
    validate_log(payload)
    summary = summarize(payload)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


def validate_log(payload: dict[str, Any]) -> None:
    if payload.get("schemaVersion") != 1:
        raise SystemExit(f"unsupported schemaVersion: {payload.get('schemaVersion')!r}")
    for key in ["sessionID", "engineMode", "events", "maximumEventCount"]:
        if key not in payload:
            raise SystemExit(f"missing required field: {key}")
    events = payload["events"]
    if not isinstance(events, list):
        raise SystemExit("events must be an array")
    maximum = payload["maximumEventCount"]
    if not isinstance(maximum, int) or maximum < 1:
        raise SystemExit("maximumEventCount must be a positive integer")
    if len(events) > maximum:
        raise SystemExit(f"event log exceeded maximumEventCount: {len(events)} > {maximum}")

    last_tick_by_epoch: dict[int, int] = {}
    for index, event in enumerate(events):
        if not isinstance(event, dict) or len(event) != 1:
            raise SystemExit(f"event {index} must be a single-key tagged object")
        tag, body = next(iter(event.items()))
        if not isinstance(body, dict):
            raise SystemExit(f"event {index} body must be an object")
        validate_event(tag, body, index, last_tick_by_epoch)


def validate_event(
    tag: str,
    body: dict[str, Any],
    index: int,
    last_tick_by_epoch: dict[int, int],
) -> None:
    if tag == "playoutTick":
        epoch = require_int(body, "epoch", index)
        tick = require_int(body, "tickIndex", index)
        previous = last_tick_by_epoch.get(epoch)
        if previous is not None and tick <= previous:
            raise SystemExit(
                f"event {index} has non-monotonic tickIndex for epoch {epoch}: {tick} <= {previous}"
            )
        last_tick_by_epoch[epoch] = tick
        require_int(body, "desiredSampleTimestamp48k", index)
        require_int(body, "playoutAtNanoseconds", index)
    elif tag == "packetArrived":
        require_int(body, "epoch", index)
        require_int(body, "frameIndex", index)
        require_int(body, "receivedAtNanoseconds", index)
        packet_size = require_int(body, "packetSizeBytes", index)
        if packet_size < 1:
            raise SystemExit(f"event {index} packetSizeBytes must be positive")
    elif tag == "packetAdmitted":
        require_int(body, "epoch", index)
        require_int(body, "frameIndex", index)
        require_string(body, "admission", index)
        require_int(body, "bufferDepthFrames", index)
    elif tag == "playoutDecision":
        require_int(body, "epoch", index)
        require_int(body, "tickIndex", index)
        require_string(body, "decision", index)
        require_int(body, "targetDelayMilliseconds", index)
        require_int(body, "bufferedFrameCount", index)
    elif tag == "decodeOutcome":
        require_int(body, "epoch", index)
        require_int(body, "frameIndex", index)
        require_string(body, "outcome", index)
        require_int(body, "pcmByteCount", index)
    elif tag == "routeChanged":
        require_string(body, "oldRoute", index)
        require_string(body, "newRoute", index)
        require_int(body, "changedAtNanoseconds", index)
    elif tag == "schedulerLate":
        require_int(body, "epoch", index)
        require_int(body, "tickIndex", index)
        require_int(body, "lateByNanoseconds", index)
    else:
        raise SystemExit(f"event {index} has unknown tag: {tag}")


def summarize(payload: dict[str, Any]) -> dict[str, Any]:
    counts: dict[str, int] = {}
    decisions: dict[str, int] = {}
    admissions: dict[str, int] = {}
    for event in payload["events"]:
        tag, body = next(iter(event.items()))
        counts[tag] = counts.get(tag, 0) + 1
        if tag == "playoutDecision":
            decision = body["decision"]
            decisions[decision] = decisions.get(decision, 0) + 1
        elif tag == "packetAdmitted":
            admission = body["admission"]
            admissions[admission] = admissions.get(admission, 0) + 1
    return {
        "schemaVersion": payload["schemaVersion"],
        "sessionID": payload["sessionID"],
        "engineMode": payload["engineMode"],
        "eventCount": len(payload["events"]),
        "eventCounts": counts,
        "admissions": admissions,
        "decisions": decisions,
    }


def require_int(body: dict[str, Any], key: str, index: int) -> int:
    value = body.get(key)
    if not isinstance(value, int):
        raise SystemExit(f"event {index} field {key} must be an integer")
    return value


def require_string(body: dict[str, Any], key: str, index: int) -> str:
    value = body.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"event {index} field {key} must be a non-empty string")
    return value


if __name__ == "__main__":
    raise SystemExit(main())
