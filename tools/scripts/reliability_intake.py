#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import shlex
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


DEFAULT_BASE_URL = "https://staging.beepbeep.to"
DEFAULT_OUTPUT_ROOT = Path("/tmp/turbo-reliability-intake")
DEFAULT_REPLAY_BASE_URL = "http://localhost:8090/s/turbo"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Collect Turbo reliability evidence from debug, TestFlight, or "
            "production-like reports."
        )
    )
    parser.add_argument("handles", nargs="*", help="User handles to inspect, usually reporter and peer.")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument(
        "--surface",
        choices=("auto", "debug", "testflight", "production"),
        default="auto",
        help="Where the report came from. This changes the summary guidance, not the evidence sources.",
    )
    parser.add_argument("--incident-id", default="", help="Shake-to-report incidentId, when available.")
    parser.add_argument("--output-dir", default="", help="Artifact directory. Defaults to a timestamped /tmp path.")
    parser.add_argument("--backend-timeout", type=int, default=8)
    parser.add_argument("--telemetry-hours", type=int, default=2)
    parser.add_argument("--telemetry-limit", type=int, default=500)
    parser.add_argument("--device", action="append", default=[], metavar="HANDLE=DEVICE_ID")
    parser.add_argument("--include-heartbeats", action="store_true")
    parser.add_argument("--no-telemetry", action="store_true")
    parser.add_argument("--compact", action="store_true", help="Do not ask merged diagnostics for full metadata.")
    parser.add_argument("--insecure", action="store_true")
    parser.add_argument("--skip-replay", action="store_true")
    parser.add_argument("--skip-audio-corpus", action="store_true")
    parser.add_argument("--replay-base-url", default=DEFAULT_REPLAY_BASE_URL)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    handles = [handle for handle in args.handles if handle.strip()]
    devices = [device for device in args.device if device.strip()]
    if not handles and not devices:
        raise SystemExit("expected at least one handle or --device HANDLE=DEVICE_ID")

    repo_root = Path(__file__).resolve().parents[2]
    output_dir = resolve_output_dir(args, handles, devices)
    output_dir.mkdir(parents=True, exist_ok=True)

    text_path = output_dir / "merged-diagnostics.txt"
    json_path = output_dir / "merged-diagnostics.json"
    summary_path = output_dir / "intake-summary.md"
    replay_dir = output_dir / "production-replay"
    audio_corpus_path = output_dir / "audio-incident-corpus.json"

    text_result = run_command(
        merged_command(args, repo_root, handles, devices, json_output=False),
        stdout_path=text_path,
        stderr_path=output_dir / "merged-diagnostics.stderr.txt",
    )
    json_result = run_command(
        merged_command(args, repo_root, handles, devices, json_output=True),
        stdout_path=json_path,
        stderr_path=output_dir / "merged-diagnostics-json.stderr.txt",
    )

    payload: dict[str, Any] | None = None
    json_error = ""
    if json_result.returncode == 0:
        try:
            payload = json.loads(json_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            json_error = f"could not parse merged diagnostics JSON: {exc}"
    else:
        json_error = "merged diagnostics JSON command failed"

    replay_result: subprocess.CompletedProcess[str] | None = None
    if payload is not None and not args.skip_replay and has_at_least_two_subjects(payload, handles):
        replay_result = run_command(
            [
                sys.executable,
                str(repo_root / "tools" / "scripts" / "convert_production_replay.py"),
                "--merged-diagnostics-json",
                str(json_path),
                "--output-dir",
                str(replay_dir),
                "--base-url",
                args.replay_base_url,
                "--name",
                replay_name(args, handles),
            ],
            stdout_path=output_dir / "production-replay.stdout.txt",
            stderr_path=output_dir / "production-replay.stderr.txt",
        )

    audio_corpus_result: subprocess.CompletedProcess[str] | None = None
    if payload is not None and not args.skip_audio_corpus:
        audio_corpus_result = run_command(
            [
                sys.executable,
                str(repo_root / "tools" / "scripts" / "audio_incident_corpus.py"),
                str(json_path),
                "--output",
                str(audio_corpus_path),
                "--name",
                audio_corpus_name(args, handles),
            ],
            stdout_path=output_dir / "audio-incident-corpus.stdout.txt",
            stderr_path=output_dir / "audio-incident-corpus.stderr.txt",
        )

    write_summary(
        summary_path,
        args=args,
        handles=handles,
        devices=devices,
        output_dir=output_dir,
        payload=payload,
        text_result=text_result,
        json_result=json_result,
        json_error=json_error,
        replay_result=replay_result,
        replay_dir=replay_dir,
        audio_corpus_result=audio_corpus_result,
        audio_corpus_path=audio_corpus_path,
    )
    write_reproduce_script(output_dir, args, handles, devices)

    print(f"reliability intake artifact: {output_dir}")
    print(f"summary: {summary_path}")
    print(f"merged diagnostics: {text_path}")
    if payload is not None:
        print(f"merged diagnostics JSON: {json_path}")
    if replay_result is not None and replay_result.returncode == 0:
        print(f"replay draft: {replay_dir / 'scenario-draft.json'}")
    if audio_corpus_result is not None and audio_corpus_result.returncode == 0:
        print(f"audio incident corpus: {audio_corpus_path}")

    if text_result.returncode != 0 or json_result.returncode != 0:
        return 1
    return 0


def resolve_output_dir(args: argparse.Namespace, handles: list[str], devices: list[str]) -> Path:
    if args.output_dir.strip():
        return Path(args.output_dir)
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    subjects = handles or [device.split("=", 1)[0] for device in devices]
    suffix = sanitize_filename("_".join(subjects)) or "report"
    return DEFAULT_OUTPUT_ROOT / f"{timestamp}_{suffix}"


def sanitize_filename(value: str) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return sanitized.strip("_")


def replay_name(args: argparse.Namespace, handles: list[str]) -> str:
    if args.incident_id.strip():
        return sanitize_filename(f"production_replay_{args.incident_id}")
    if handles:
        return sanitize_filename(f"production_replay_{'_'.join(handles)}")
    return "production_replay"


def audio_corpus_name(args: argparse.Namespace, handles: list[str]) -> str:
    if args.incident_id.strip():
        return sanitize_filename(f"audio_incident_{args.incident_id}")
    if handles:
        return sanitize_filename(f"audio_incident_{'_'.join(handles)}")
    return "audio_incident"


def merged_command(
    args: argparse.Namespace,
    repo_root: Path,
    handles: list[str],
    devices: list[str],
    *,
    json_output: bool,
) -> list[str]:
    command = [
        sys.executable,
        str(repo_root / "tools" / "scripts" / "merged_diagnostics.py"),
        "--base-url",
        args.base_url,
        "--backend-timeout",
        str(args.backend_timeout),
    ]
    if args.insecure:
        command.append("--insecure")
    if args.no_telemetry:
        command.append("--no-telemetry")
    else:
        command.extend(["--telemetry-hours", str(args.telemetry_hours)])
        command.extend(["--telemetry-limit", str(args.telemetry_limit)])
    if args.include_heartbeats:
        command.append("--include-heartbeats")
    if not args.compact:
        command.append("--full-metadata")
    for device in devices:
        command.extend(["--device", device])
    if json_output:
        command.append("--json")
    command.extend(handles)
    return command


def run_command(
    command: list[str],
    *,
    stdout_path: Path,
    stderr_path: Path,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, text=True, capture_output=True)
    stdout_path.write_text(result.stdout, encoding="utf-8")
    stderr_path.write_text(result.stderr, encoding="utf-8")
    return result


def write_summary(
    path: Path,
    *,
    args: argparse.Namespace,
    handles: list[str],
    devices: list[str],
    output_dir: Path,
    payload: dict[str, Any] | None,
    text_result: subprocess.CompletedProcess[str],
    json_result: subprocess.CompletedProcess[str],
    json_error: str,
    replay_result: subprocess.CompletedProcess[str] | None,
    replay_dir: Path,
    audio_corpus_result: subprocess.CompletedProcess[str] | None,
    audio_corpus_path: Path,
) -> None:
    lines: list[str] = [
        "# Reliability Intake",
        "",
        "## Request",
        "",
        f"- surface: `{args.surface}`",
        f"- base URL: `{args.base_url}`",
        f"- handles: `{', '.join(handles) if handles else 'none'}`",
        f"- devices: `{', '.join(devices) if devices else 'none'}`",
        f"- incident ID: `{args.incident_id.strip() or 'none'}`",
        f"- output: `{output_dir}`",
        "",
        "## Collection",
        "",
        f"- merged diagnostics text exit: `{text_result.returncode}`",
        f"- merged diagnostics JSON exit: `{json_result.returncode}`",
    ]

    if json_error:
        lines.append(f"- JSON parse/status: `{json_error}`")

    if payload is not None:
        reports = payload_list(payload, "reports")
        telemetry_reports = payload_list(payload, "telemetrySnapshotReports")
        warnings = payload_list(payload, "sourceWarnings")
        violations = payload_list(payload, "violations")
        current_violations, historical_violations = split_violations(payload)
        telemetry_count = payload.get("telemetryEventCount", 0)
        incident_found = incident_marker_found(payload, args.incident_id)

        lines.extend(
            [
                f"- backend latest snapshots: `{len(reports)}`",
                f"- telemetry snapshot facts: `{len(telemetry_reports)}`",
                f"- telemetry events: `{telemetry_count}`",
                f"- source warnings: `{len(warnings)}`",
                f"- invariant violations: `{len(violations)}`",
                f"- current invariant violations: `{len(current_violations)}`",
                f"- historical invariant violations: `{len(historical_violations)}`",
            ]
        )
        if args.incident_id.strip():
            lines.append(f"- incident marker found: `{'yes' if incident_found else 'no'}`")

        if reports:
            lines.extend(["", "## Snapshots", ""])
            for report in reports:
                lines.append(
                    "- "
                    + " ".join(
                        [
                            f"`{report.get('handle', 'unknown')}`",
                            f"device=`{report.get('deviceId', 'unknown')}`",
                            f"uploadedAt=`{report.get('uploadedAt', 'unknown')}`",
                            f"appVersion=`{report.get('appVersion', 'unknown')}`",
                        ]
                    )
                )

        if telemetry_reports:
            lines.extend(["", "## Telemetry Snapshot Facts", ""])
            for report in telemetry_reports:
                snapshot = report.get("snapshot")
                snapshot = snapshot if isinstance(snapshot, dict) else {}
                lines.append(
                    "- "
                    + " ".join(
                        [
                            f"`{report.get('handle', 'unknown')}`",
                            f"device=`{report.get('deviceId', 'unknown')}`",
                            f"uploadedAt=`{report.get('uploadedAt', 'unknown')}`",
                            f"phase=`{snapshot.get('selectedConversationPhase', 'unknown')}`",
                            f"backendReadiness=`{snapshot.get('backendReadiness', 'unknown')}`",
                        ]
                    )
                )

        if warnings:
            lines.extend(["", "## Source Warnings", ""])
            for warning in warnings:
                lines.append(
                    f"- `{warning.get('subject', 'unknown')}` "
                    f"{warning.get('source', 'unknown')}: {warning.get('message', '')}"
                )

        if current_violations:
            lines.extend(["", "## Current Invariant Violations", ""])
            for violation in current_violations[:20]:
                timestamp = violation.get("timestamp") or "no timestamp"
                lines.append(
                    f"- `{violation.get('invariantId', 'unknown')}` "
                    f"scope=`{violation.get('scope', 'unknown')}` "
                    f"source=`{violation.get('source', 'unknown')}` "
                    f"subject=`{violation.get('subject', 'unknown')}` "
                    f"at `{timestamp}`"
                )
            if len(current_violations) > 20:
                lines.append(f"- ... `{len(current_violations) - 20}` more")

        if historical_violations:
            lines.extend(["", "## Historical Invariant Violations", ""])
            for violation in historical_violations[:20]:
                timestamp = violation.get("timestamp") or "no timestamp"
                lines.append(
                    f"- `{violation.get('invariantId', 'unknown')}` "
                    f"scope=`{violation.get('scope', 'unknown')}` "
                    f"source=`{violation.get('source', 'unknown')}` "
                    f"subject=`{violation.get('subject', 'unknown')}` "
                    f"at `{timestamp}`"
                )
            if len(historical_violations) > 20:
                lines.append(f"- ... `{len(historical_violations) - 20}` more")

        shake_events = find_shake_events(payload)
        if shake_events:
            lines.extend(["", "## Shake Events", ""])
            for event in shake_events[:10]:
                lines.append(f"- `{event}`")

    lines.extend(["", "## Replay", ""])
    if replay_result is None:
        lines.append("- replay draft: `not attempted`")
    elif replay_result.returncode == 0:
        lines.append(f"- replay draft: `{replay_dir / 'scenario-draft.json'}`")
        lines.append(f"- reproduce script: `{replay_dir / 'reproduce.sh'}`")
    else:
        lines.append(f"- replay draft failed with exit `{replay_result.returncode}`")

    lines.extend(["", "## Audio Incident Corpus", ""])
    if audio_corpus_result is None:
        lines.append("- audio corpus: `not attempted`")
    elif audio_corpus_result.returncode == 0:
        lines.append(f"- audio corpus: `{audio_corpus_path}`")
        lines.append(f"- replay: `just audio-incident-replay {audio_corpus_path}`")
        lines.append(f"- mutate: `just audio-incident-mutate {audio_corpus_path}`")
    else:
        lines.append(
            f"- audio corpus: `not extracted` exit=`{audio_corpus_result.returncode}` "
            f"stderr=`{audio_corpus_path.with_name('audio-incident-corpus.stderr.txt')}`"
        )

    lines.extend(["", "## How To Read This", ""])
    lines.extend(surface_guidance(args.surface))

    lines.extend(
        [
            "",
            "## Agent Next Step",
            "",
            "- Start with source warnings. Missing backend latest snapshots in a current debug build are a diagnostics/autopublish bug.",
            "- Read invariant IDs before reconstructing timelines by hand.",
            "- Classify ownership before editing: backend/shared truth, client projection, Apple/PTT/audio adapter, or missing invariant.",
            "- Convert the failure into the narrowest permanent proof, then fix the owning subsystem.",
            "- Verify with the targeted proof first, then the appropriate reliability gate.",
        ]
    )

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def surface_guidance(surface: str) -> list[str]:
    if surface == "debug":
        return [
            "- Debug builds should provide backend latest diagnostics plus compact telemetry when credentials are available.",
            "- Manual upload is a fallback. If recent debug activity has no backend latest snapshot, investigate diagnostics publishing.",
        ]
    if surface in {"testflight", "production"}:
        return [
            "- TestFlight and production-like reports depend more heavily on telemetry alerts and shake markers.",
            "- The current latest-diagnostics URL is not immutable; match `incidentId` and `uploadedAt` before trusting the transcript.",
            "- Backend latest diagnostics still carries the full transcript when shake-to-report uploaded successfully.",
        ]
    return [
        "- Auto mode collects both backend latest diagnostics and telemetry when possible.",
        "- Treat telemetry as the compact event stream and backend latest diagnostics as the full transcript/state anchor.",
    ]


def payload_list(payload: dict[str, Any], key: str) -> list[dict[str, Any]]:
    value = payload.get(key)
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    return []


def split_violations(payload: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    has_split_keys = "currentViolations" in payload or "historicalViolations" in payload
    if has_split_keys:
        return (
            payload_list(payload, "currentViolations"),
            payload_list(payload, "historicalViolations"),
        )
    return (payload_list(payload, "violations"), [])


def has_at_least_two_subjects(payload: dict[str, Any], handles: list[str]) -> bool:
    del handles
    subjects: set[str] = set()
    for report in payload_list(payload, "reports"):
        handle = report.get("handle")
        if isinstance(handle, str) and handle:
            subjects.add(handle)
    for event in payload_list(payload, "telemetryEvents"):
        handle = event.get("handle")
        if isinstance(handle, str) and handle:
            subjects.add(handle)
        peer = event.get("peerHandle")
        if isinstance(peer, str) and peer:
            subjects.add(peer)
    return len(subjects) >= 2


def incident_marker_found(payload: dict[str, Any], incident_id: str) -> bool:
    incident_id = incident_id.strip()
    if not incident_id:
        return False
    return incident_id in json.dumps(payload, sort_keys=True)


def find_shake_events(payload: dict[str, Any]) -> list[str]:
    events: list[str] = []
    for event in payload_list(payload, "telemetryEvents"):
        event_name = str(event.get("eventName", ""))
        message = str(event.get("message", ""))
        if event_name == "ios.problem_report.shake" or "Shake report requested" in message:
            handle = event.get("handle", "unknown")
            timestamp = event.get("timestamp", "unknown")
            incident = incident_from_event(event)
            suffix = f" incidentId={incident}" if incident else ""
            events.append(f"{timestamp} {handle} {event_name or message}{suffix}")
    for item in payload.get("timeline", []) if isinstance(payload.get("timeline"), list) else []:
        if not isinstance(item, dict):
            continue
        line = str(item.get("line", ""))
        if "Shake report requested" in line:
            events.append(f"{item.get('timestamp', 'unknown')} {line}")
    return events


def incident_from_event(event: dict[str, Any]) -> str:
    metadata = event.get("metadata")
    if isinstance(metadata, dict):
        for key in ("incidentId", "incidentID", "incident_id"):
            value = metadata.get(key)
            if isinstance(value, str) and value:
                return value
    metadata_text = event.get("metadataText")
    if isinstance(metadata_text, str):
        match = re.search(r"incidentI[Dd]\"?\s*[:=]\s*\"?([A-Za-z0-9_.:-]+)", metadata_text)
        if match:
            return match.group(1)
    return ""


def write_reproduce_script(
    output_dir: Path,
    args: argparse.Namespace,
    handles: list[str],
    devices: list[str],
) -> None:
    script_path = output_dir / "reproduce.sh"
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--base-url",
        args.base_url,
        "--surface",
        args.surface,
        "--backend-timeout",
        str(args.backend_timeout),
        "--telemetry-hours",
        str(args.telemetry_hours),
        "--telemetry-limit",
        str(args.telemetry_limit),
        "--output-dir",
        str(output_dir),
    ]
    if args.incident_id.strip():
        command.extend(["--incident-id", args.incident_id.strip()])
    if args.insecure:
        command.append("--insecure")
    if args.no_telemetry:
        command.append("--no-telemetry")
    if args.include_heartbeats:
        command.append("--include-heartbeats")
    if args.compact:
        command.append("--compact")
    if args.skip_replay:
        command.append("--skip-replay")
    if args.skip_audio_corpus:
        command.append("--skip-audio-corpus")
    for device in devices:
        command.extend(["--device", device])
    command.extend(handles)
    script_path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + shlex.join(command) + "\n", encoding="utf-8")
    mode = script_path.stat().st_mode
    script_path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


if __name__ == "__main__":
    raise SystemExit(main())
