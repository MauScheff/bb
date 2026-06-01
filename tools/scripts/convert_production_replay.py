#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import stat
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


DEFAULT_BASE_URL = "http://localhost:8090/s/turbo"
DEFAULT_SCENARIO_HANDLES = ["@avery", "@blake", "@casey", "@devon"]
HANDLE_RE = re.compile(r"@[A-Za-z0-9_.-]+")
SUBJECT_RE = re.compile(r"^\[(?P<subject>[^\]]+)\]")
KEY_VALUE_HANDLE_RE = re.compile(r"(?:selectedHandle|selectedContact|peer_handle|peerHandle|handle)=(@[A-Za-z0-9_.-]+)")
KEY_VALUE_DEVICE_RE = re.compile(r"(?:deviceId|device_id|targetDeviceId|sender_device_id)=([A-Za-z0-9_.:\-]+)")


@dataclass(frozen=True)
class SourceParticipant:
    handle: str
    device_id: str
    snapshot: dict[str, str]


@dataclass(frozen=True)
class InferredAction:
    timestamp: str | None
    actor: str
    action_type: str
    source_line: str
    confidence: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Convert merged production diagnostics JSON into a redacted replay "
            "artifact and best-effort simulator scenario draft."
        )
    )
    parser.add_argument("--merged-diagnostics-json", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--name", default="")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--preserve-source-identities", action="store_true")
    parser.add_argument(
        "--preserve-scenario-handles",
        action="store_true",
        help="Use source handles in scenario-draft.json instead of safe replay handles.",
    )
    parser.add_argument("--max-inferred-actions", type=int, default=80)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    payload = read_json(Path(args.merged_diagnostics_json))
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    participants = discover_participants(payload)
    if len(participants) < 2:
        raise SystemExit("expected diagnostics for at least two handles or devices")

    scenario_name = scenario_name_from(args.name, payload)
    source_handles = [participant.handle for participant in participants]
    source_to_actor = {handle: actor_key(index) for index, handle in enumerate(source_handles)}
    source_to_scenario_handle = scenario_handle_mapping(
        source_handles,
        preserve=args.preserve_scenario_handles,
    )
    source_to_redacted = {
        participant.handle: f"source-actor-{source_to_actor[participant.handle]}"
        for participant in participants
    }
    source_devices_to_redacted = {
        participant.device_id: f"source-device-{source_to_actor[participant.handle]}"
        for participant in participants
        if participant.device_id
    }

    timeline = normalized_timeline(payload)
    inferred_actions = infer_actions(
        timeline,
        source_to_actor,
        max_actions=args.max_inferred_actions,
    )

    scenario = build_scenario(
        name=scenario_name,
        base_url=args.base_url,
        participants=participants,
        source_to_actor=source_to_actor,
        source_to_scenario_handle=source_to_scenario_handle,
        inferred_actions=inferred_actions,
    )
    replay_payload = build_replay_payload(
        source_path=Path(args.merged_diagnostics_json),
        scenario=scenario,
        original_payload=payload,
        participants=participants,
        source_to_actor=source_to_actor,
        source_to_scenario_handle=source_to_scenario_handle,
        source_to_redacted=source_to_redacted,
        source_devices_to_redacted=source_devices_to_redacted,
        timeline=timeline,
        inferred_actions=inferred_actions,
        preserve_source_identities=args.preserve_source_identities,
    )

    write_json(output_dir / "scenario-draft.json", scenario)
    write_json(output_dir / "production-replay.json", replay_payload)
    write_json(output_dir / "metadata.json", replay_metadata(output_dir, scenario, participants))
    write_readme(output_dir, scenario_name)
    write_reproduce_script(output_dir, scenario, participants)

    print(f"production replay artifact: {output_dir}")
    print(f"scenario draft: {output_dir / 'scenario-draft.json'}")
    return 0


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise SystemExit(f"expected JSON object in {path}")
    return payload


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def scenario_name_from(explicit_name: str, payload: dict[str, Any]) -> str:
    if explicit_name.strip():
        return sanitize_name(explicit_name)

    reports = payload.get("reports")
    if isinstance(reports, list):
        for report in reports:
            if isinstance(report, dict):
                scenario_name = report.get("scenarioName")
                if isinstance(scenario_name, str) and scenario_name.strip():
                    return sanitize_name(f"production_replay_{scenario_name}")

    invariant_ids = sorted(invariant_ids_from(payload))
    if invariant_ids:
        return sanitize_name(f"production_replay_{invariant_ids[0]}")

    return f"production_replay_{time.strftime('%Y%m%d_%H%M%S')}"


def sanitize_name(value: str) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9_]+", "_", value.strip())
    sanitized = re.sub(r"_+", "_", sanitized).strip("_")
    return sanitized or "production_replay"


def discover_participants(payload: dict[str, Any]) -> list[SourceParticipant]:
    by_handle: dict[str, SourceParticipant] = {}
    ordered_handles: list[str] = []

    def add(handle: str, device_id: str = "", snapshot: dict[str, str] | None = None) -> None:
        normalized = normalize_handle(handle)
        if not normalized:
            return
        existing = by_handle.get(normalized)
        merged_snapshot = dict(existing.snapshot) if existing else {}
        if snapshot:
            merged_snapshot.update(snapshot)
        merged_device_id = device_id or (existing.device_id if existing else "")
        by_handle[normalized] = SourceParticipant(
            handle=normalized,
            device_id=merged_device_id,
            snapshot=merged_snapshot,
        )
        if normalized not in ordered_handles:
            ordered_handles.append(normalized)

    reports = payload.get("reports")
    if isinstance(reports, list):
        for report in reports:
            if not isinstance(report, dict):
                continue
            handle = str(report.get("handle") or "")
            snapshot = snapshot_as_strings(report.get("snapshot"))
            add(handle, str(report.get("deviceId") or ""), snapshot)

    telemetry_events = payload.get("telemetryEvents")
    if isinstance(telemetry_events, list):
        for event in telemetry_events:
            if not isinstance(event, dict):
                continue
            add(str(event.get("handle") or ""), str(event.get("deviceId") or ""))
            peer_handle = str(event.get("peerHandle") or "")
            if peer_handle:
                add(peer_handle)

    for event in normalized_timeline(payload):
        subject = event.get("subject") or ""
        if subject.startswith("@"):
            add(subject)
        for handle in HANDLE_RE.findall(event.get("line") or ""):
            add(handle)

    return [by_handle[handle] for handle in ordered_handles]


def snapshot_as_strings(value: object) -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    return {
        str(key): bool_text(raw_value) if isinstance(raw_value, bool) else str(raw_value)
        for key, raw_value in value.items()
    }


def normalize_handle(value: str) -> str:
    text = value.strip()
    if not text:
        return ""
    if not text.startswith("@"):
        text = f"@{text}"
    return text


def actor_key(index: int) -> str:
    if index < 26:
        return chr(ord("a") + index)
    return f"p{index + 1}"


def scenario_handle_mapping(source_handles: list[str], *, preserve: bool) -> dict[str, str]:
    if preserve:
        return {handle: handle for handle in source_handles}
    return {
        handle: DEFAULT_SCENARIO_HANDLES[index]
        if index < len(DEFAULT_SCENARIO_HANDLES)
        else f"@replay{index + 1}"
        for index, handle in enumerate(source_handles)
    }


def normalized_timeline(payload: dict[str, Any]) -> list[dict[str, str | None]]:
    raw_timeline = payload.get("timeline")
    if not isinstance(raw_timeline, list):
        return []

    events: list[dict[str, str | None]] = []
    for raw_event in raw_timeline:
        if not isinstance(raw_event, dict):
            continue
        line = str(raw_event.get("line") or "")
        timestamp = raw_event.get("timestamp")
        subject = raw_event.get("subject")
        if not isinstance(subject, str) or not subject:
            subject = subject_from_line(line)
        events.append(
            {
                "timestamp": str(timestamp) if timestamp is not None else None,
                "subject": subject,
                "line": line,
            }
        )
    return events


def subject_from_line(line: str) -> str | None:
    match = SUBJECT_RE.match(line)
    if not match:
        return None
    subject = match.group("subject").strip()
    return subject if subject else None


def infer_actions(
    timeline: list[dict[str, str | None]],
    source_to_actor: dict[str, str],
    *,
    max_actions: int,
) -> list[InferredAction]:
    actions: list[InferredAction] = []
    last_signature: tuple[str, str] | None = None
    last_timestamp: datetime | None = None

    for event in timeline:
        if len(actions) >= max_actions:
            break
        line = event.get("line") or ""
        subject = event.get("subject") or ""
        actor = source_to_actor.get(subject)
        if actor is None:
            actor = actor_from_line(line, source_to_actor)
        if actor is None:
            continue

        action_type = infer_action_type(line)
        if action_type is None:
            continue

        timestamp_text = event.get("timestamp")
        timestamp = parse_timestamp(timestamp_text)
        signature = (actor, action_type)
        if signature == last_signature and timestamps_close(last_timestamp, timestamp):
            continue
        last_signature = signature
        last_timestamp = timestamp
        actions.append(
            InferredAction(
                timestamp=timestamp_text,
                actor=actor,
                action_type=action_type,
                source_line=line,
                confidence="inferred",
            )
        )

    return actions


def actor_from_line(line: str, source_to_actor: dict[str, str]) -> str | None:
    for handle in HANDLE_RE.findall(line):
        actor = source_to_actor.get(handle)
        if actor is not None:
            return actor
    return None


def infer_action_type(line: str) -> str | None:
    normalized = normalize_event_text(line)
    rules: list[tuple[str, tuple[str, ...]]] = [
        ("beginTransmit", ("begin transmit", "begintransmit", "transmit-start", "started transmit")),
        ("endTransmit", ("end transmit", "endtransmit", "transmit-stop", "stopped transmit")),
        ("disconnectWebSocket", ("disconnectwebsocket", "websocket disconnected", "websocket disconnect")),
        ("reconnectWebSocket", ("reconnectwebsocket", "websocket reconnected", "resume websocket")),
        ("backgroundApp", ("backgroundapp", "did enter background", "applicationstate=background", "state=background")),
        ("foregroundApp", ("foregroundapp", "did become active", "applicationstate=active", "state=active")),
        ("disconnect", ("disconnect requested", "leave requested", "disconnect tapped", "left channel", "local leave")),
        ("connect", ("connect requested", "join requested", "joinchannel", "join channel", "accept request", "request accepted")),
        ("openFriend", ("open friend", "opened friend", "friend lookup", "selected contact", "selectedhandle=")),
        ("refreshChannelState", ("refreshchannelstate", "refresh channel state", "channel-state", "channel readiness")),
        ("refreshBeeps", ("refreshbeeps", "refresh beep", "incoming-beeps", "outgoing-beeps")),
        ("refreshContactSummaries", ("refreshcontactsummaries", "refresh contact", "contact-summaries")),
        ("reconnectBackend", ("reconnectbackend", "reconnect backend", "control plane reconnect")),
    ]
    for action_type, phrases in rules:
        if any(phrase in normalized for phrase in phrases):
            return action_type
    return None


def normalize_event_text(line: str) -> str:
    return re.sub(r"\s+", " ", line.replace("_", " ").lower())


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def timestamps_close(left: datetime | None, right: datetime | None) -> bool:
    if left is None or right is None:
        return left is None and right is None
    return abs((right - left).total_seconds()) <= 0.25


def build_scenario(
    *,
    name: str,
    base_url: str,
    participants: list[SourceParticipant],
    source_to_actor: dict[str, str],
    source_to_scenario_handle: dict[str, str],
    inferred_actions: list[InferredAction],
) -> dict[str, Any]:
    scenario_participants: dict[str, dict[str, str]] = {}
    for participant in participants:
        actor = source_to_actor[participant.handle]
        scenario_participants[actor] = {
            "handle": source_to_scenario_handle[participant.handle],
            "deviceId": f"sim-production-replay-{actor}",
        }

    steps: list[dict[str, Any]] = []
    open_actions = opening_actions(participants, source_to_actor)
    if open_actions:
        steps.append(
            {
                "description": "open inferred friend selections",
                "actions": open_actions,
            }
        )

    opened_actors = {
        action["actor"]
        for action in open_actions
        if action.get("type") == "openFriend"
    }
    for action in inferred_actions:
        if action.action_type == "openFriend" and action.actor in opened_actors:
            continue
        scenario_action: dict[str, Any] = {
            "actor": action.actor,
            "type": action.action_type,
        }
        if action.action_type == "openFriend":
            friend = default_friend_actor(action.actor, scenario_participants)
            if friend is None:
                continue
            scenario_action["friend"] = friend
        steps.append(
            {
                "description": describe_inferred_action(action),
                "actions": [scenario_action],
            }
        )

    final_refreshes = [
        {"actor": actor, "type": "refreshContactSummaries"}
        for actor in sorted(scenario_participants.keys())
    ] + [
        {"actor": actor, "type": "refreshChannelState"}
        for actor in sorted(scenario_participants.keys())
    ]
    if final_refreshes:
        steps.append(
            {
                "description": "refresh projections for strict merged diagnostics",
                "actions": final_refreshes,
            }
        )

    return {
        "name": name,
        "baseURL": base_url,
        "participants": scenario_participants,
        "steps": steps,
    }


def opening_actions(
    participants: list[SourceParticipant],
    source_to_actor: dict[str, str],
) -> list[dict[str, str]]:
    actions: list[dict[str, str]] = []
    participant_actors = {participant.handle: source_to_actor[participant.handle] for participant in participants}
    for participant in participants:
        actor = participant_actors[participant.handle]
        selected = selected_handle_from_snapshot(participant.snapshot)
        friend = participant_actors.get(selected or "")
        if friend is None:
            friend = default_friend_actor(actor, {value: {} for value in participant_actors.values()})
        if friend is not None:
            actions.append({"actor": actor, "type": "openFriend", "friend": friend})
    return dedupe_action_dicts(actions)


def default_friend_actor(actor: str, participants: dict[str, Any]) -> str | None:
    keys = sorted(participants.keys())
    if len(keys) < 2:
        return None
    if actor == keys[0]:
        return keys[1]
    return keys[0]


def selected_handle_from_snapshot(snapshot: dict[str, str]) -> str | None:
    for key in ("selectedContact", "selectedHandle"):
        value = snapshot.get(key)
        if value and value.startswith("@"):
            return value
    return None


def dedupe_action_dicts(actions: list[dict[str, str]]) -> list[dict[str, str]]:
    seen: set[tuple[tuple[str, str], ...]] = set()
    deduped: list[dict[str, str]] = []
    for action in actions:
        key = tuple(sorted(action.items()))
        if key in seen:
            continue
        seen.add(key)
        deduped.append(action)
    return deduped


def describe_inferred_action(action: InferredAction) -> str:
    if action.timestamp:
        return f"{action.action_type} inferred from {action.timestamp}"
    return f"{action.action_type} inferred from diagnostics"


def build_replay_payload(
    *,
    source_path: Path,
    scenario: dict[str, Any],
    original_payload: dict[str, Any],
    participants: list[SourceParticipant],
    source_to_actor: dict[str, str],
    source_to_scenario_handle: dict[str, str],
    source_to_redacted: dict[str, str],
    source_devices_to_redacted: dict[str, str],
    timeline: list[dict[str, str | None]],
    inferred_actions: list[InferredAction],
    preserve_source_identities: bool,
) -> dict[str, Any]:
    def scrub(text: str | None) -> str | None:
        if text is None or preserve_source_identities:
            return text
        scrubbed = text
        for source, replacement in sorted(source_to_redacted.items(), key=lambda item: len(item[0]), reverse=True):
            scrubbed = scrubbed.replace(source, replacement)
        for source, replacement in sorted(source_devices_to_redacted.items(), key=lambda item: len(item[0]), reverse=True):
            scrubbed = scrubbed.replace(source, replacement)
        for match in KEY_VALUE_HANDLE_RE.findall(scrubbed):
            if match not in source_to_redacted:
                scrubbed = scrubbed.replace(match, "source-handle")
        for match in KEY_VALUE_DEVICE_RE.findall(scrubbed):
            if match.startswith("source-device-"):
                continue
            if match not in source_devices_to_redacted:
                scrubbed = scrubbed.replace(match, "source-device")
        return scrubbed

    def scrub_json(value: object) -> object:
        if preserve_source_identities:
            return value
        if isinstance(value, str):
            return scrub(value)
        if isinstance(value, list):
            return [scrub_json(item) for item in value]
        if isinstance(value, dict):
            return {str(key): scrub_json(item) for key, item in value.items()}
        return value

    source_participants: list[dict[str, Any]] = []
    for participant in participants:
        actor = source_to_actor[participant.handle]
        source_participants.append(
            {
                "actor": actor,
                "sourceHandle": participant.handle if preserve_source_identities else source_to_redacted[participant.handle],
                "sourceDeviceId": (
                    participant.device_id
                    if preserve_source_identities
                    else source_devices_to_redacted.get(participant.device_id, "")
                ),
                "scenarioHandle": source_to_scenario_handle[participant.handle],
                "scenarioDeviceId": scenario["participants"][actor]["deviceId"],
            }
        )

    return {
        "schemaVersion": 1,
        "source": {
            "kind": "merged-diagnostics-json",
            "path": str(source_path) if preserve_source_identities else source_path.name,
            "identitiesRedacted": not preserve_source_identities,
        },
        "scenarioName": scenario["name"],
        "participants": source_participants,
        "invariantIds": sorted(invariant_ids_from(original_payload)),
        "diagnosticGroups": scrub_json(original_payload.get("diagnosticGroups", [])),
        "timeline": [
            {
                "timestamp": event.get("timestamp"),
                "subject": scrub(event.get("subject")),
                "line": scrub(event.get("line")),
            }
            for event in timeline
        ],
        "inferredActions": [
            {
                "timestamp": action.timestamp,
                "actor": action.actor,
                "type": action.action_type,
                "confidence": action.confidence,
                "sourceLine": scrub(action.source_line),
            }
            for action in inferred_actions
        ],
        "suggestedFinalExpectations": suggested_expectations(
            participants,
            source_to_actor,
            source_to_scenario_handle,
        ),
        "notes": [
            "scenario-draft.json is intentionally a best-effort action replay.",
            "Use strict merged diagnostics after running it to decide whether the production invariant reproduced.",
            "Promote only minimized, stable drafts into shared/scenarios/.",
        ],
    }


def invariant_ids_from(payload: dict[str, Any]) -> set[str]:
    ids: set[str] = set()
    for key in (
        "violations",
        "currentViolations",
        "historicalViolations",
        "explicitInvariantViolations",
        "backendInvariantViolations",
    ):
        collect_invariant_ids(payload.get(key), ids)
    reports = payload.get("reports")
    if isinstance(reports, list):
        for report in reports:
            if isinstance(report, dict):
                collect_invariant_ids(report.get("explicitInvariantViolations"), ids)
                collect_invariant_ids(report.get("backendInvariantViolations"), ids)
    telemetry_events = payload.get("telemetryEvents")
    if isinstance(telemetry_events, list):
        for event in telemetry_events:
            if isinstance(event, dict):
                invariant_id = str(event.get("invariantId") or "").strip()
                if invariant_id:
                    ids.add(invariant_id)
    return ids


def collect_invariant_ids(value: object, ids: set[str]) -> None:
    if not isinstance(value, list):
        return
    for item in value:
        if isinstance(item, dict):
            invariant_id = str(item.get("invariantId") or "").strip()
            if invariant_id:
                ids.add(invariant_id)


def suggested_expectations(
    participants: list[SourceParticipant],
    source_to_actor: dict[str, str],
    source_to_scenario_handle: dict[str, str],
) -> dict[str, Any]:
    expectations: dict[str, Any] = {}
    for participant in participants:
        actor = source_to_actor[participant.handle]
        snapshot = participant.snapshot
        expectation: dict[str, Any] = {}
        selected = selected_handle_from_snapshot(snapshot)
        if selected:
            expectation["selectedHandle"] = source_to_scenario_handle.get(selected, selected)
        for source_key, target_key in (
            ("selectedConversationPhase", "phase"),
            ("selectedConversationStatus", "selectedStatus"),
            ("isJoined", "isJoined"),
            ("isTransmitting", "isTransmitting"),
            ("selectedConversationCanTransmit", "canTransmitNow"),
        ):
            value = snapshot.get(source_key)
            if value is None or value == "none":
                continue
            if target_key in {"isJoined", "isTransmitting", "canTransmitNow"}:
                expectation[target_key] = parse_bool(value)
            else:
                expectation[target_key] = value
        if expectation:
            expectations[actor] = expectation
    return expectations


def parse_bool(value: str) -> bool | str:
    lowered = value.strip().lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    return value


def bool_text(value: bool) -> str:
    return "true" if value else "false"


def replay_metadata(output_dir: Path, scenario: dict[str, Any], participants: list[SourceParticipant]) -> dict[str, Any]:
    return {
        "scenarioName": scenario["name"],
        "scenarioDraft": str((output_dir / "scenario-draft.json").resolve()),
        "productionReplay": str((output_dir / "production-replay.json").resolve()),
        "baseURL": scenario["baseURL"],
        "participants": scenario["participants"],
        "sourceParticipantCount": len(participants),
    }


def write_readme(output_dir: Path, scenario_name: str) -> None:
    content = f"""# Production Replay Artifact

This directory was generated from merged diagnostics JSON.

Files:

- `production-replay.json`: redacted source timeline, invariant IDs, and inferred actions
- `scenario-draft.json`: best-effort simulator scenario input
- `metadata.json`: local artifact metadata
- `reproduce.sh`: run the scenario draft and strict merged diagnostics

The scenario draft is not a proof by itself. The proof is whether strict merged
diagnostics reproduces the same invariant after the generated scenario runs.

Scenario: `{scenario_name}`
"""
    (output_dir / "README.md").write_text(content, encoding="utf-8")


def write_reproduce_script(output_dir: Path, scenario: dict[str, Any], participants: list[SourceParticipant]) -> None:
    repo_root = Path.cwd()
    scenario_file = output_dir / "scenario-draft.json"
    participant_items = sorted(scenario["participants"].items())
    first = participant_items[0]
    second = participant_items[1]
    device_args = []
    for _, participant in participant_items:
        device_args.extend(["--device", f"{participant['handle']}={participant['deviceId']}"])

    scenario_command = [
        "python3",
        "tools/scripts/run_simulator_scenarios.py",
        "--scenario-file",
        str(scenario_file),
        "--scenario",
        scenario["name"],
        "--base-url",
        scenario["baseURL"],
        "--handle-a",
        first[1]["handle"],
        "--handle-b",
        second[1]["handle"],
        "--device-id-a",
        first[1]["deviceId"],
        "--device-id-b",
        second[1]["deviceId"],
    ]
    diagnostics_command = [
        "python3",
        "tools/scripts/merged_diagnostics.py",
        "--base-url",
        scenario["baseURL"],
        "--no-telemetry",
        "--fail-on-violations",
        *device_args,
    ]
    script = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f"cd {shell_quote(str(repo_root))}\n"
        + " ".join(shell_quote(part) for part in scenario_command)
        + "\n"
        + " ".join(shell_quote(part) for part in diagnostics_command)
        + "\n"
    )
    path = output_dir / "reproduce.sh"
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    raise SystemExit(main())
