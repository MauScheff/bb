#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import physical_device_boundary_collect


DEFAULT_READINESS = "/tmp/turbo-self-hosted-cutover-readiness-current.json"
DEFAULT_OUTPUT = "/tmp/turbo-physical-device-boundary-status.json"
DEFAULT_LAUNCHABILITY = "/tmp/turbo-device-launch-connected-current.json"
DEFAULT_RUNS = [
    "/tmp/turbo-physical-direct-quic-run-current",
    "/tmp/turbo-physical-lockscreen-wake-run",
    "/tmp/turbo-physical-fallback-relay-run",
    "/tmp/turbo-physical-foreground-ptt-run",
    "/tmp/turbo-physical-device-boundary-run",
]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Summarize physical-device boundary readiness from the canonical "
            "cutover readiness artifact and recent target-cell run summaries."
        )
    )
    parser.add_argument("--readiness", default=DEFAULT_READINESS)
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--device-snapshot",
        default="",
        help="Optional JSON file produced by `python3 tools/scripts/device_app.py list --json`.",
    )
    parser.add_argument(
        "--skip-device-list",
        action="store_true",
        help="Do not run `tools/scripts/device_app.py list --json` for current physical-device state.",
    )
    parser.add_argument(
        "--lock-state-snapshot",
        default="",
        help="Optional JSON file produced by `python3 tools/scripts/device_app.py lock-state-connected --json`.",
    )
    parser.add_argument(
        "--skip-lock-state",
        action="store_true",
        help="Do not run `tools/scripts/device_app.py lock-state-connected --json` for advisory CoreDevice reachability.",
    )
    parser.add_argument(
        "--launchability-snapshot",
        default=DEFAULT_LAUNCHABILITY,
        help="Optional JSON file produced by `just device-launch-connected-json`.",
    )
    parser.add_argument(
        "--skip-launchability",
        action="store_true",
        help="Do not read the current launchability snapshot.",
    )
    parser.add_argument(
        "--run",
        action="append",
        default=[],
        help="Run directory or physical-device-boundary-collect.json path. May be repeated.",
    )
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    run_inputs = args.run or DEFAULT_RUNS
    current_devices = None
    device_snapshot_error = None
    lock_states = None
    lock_state_error = None
    launchability = None
    launchability_error = None
    if args.device_snapshot:
        current_devices = read_json(Path(args.device_snapshot))
        if not isinstance(current_devices, list):
            device_snapshot_error = f"device snapshot missing or invalid: {args.device_snapshot}"
            current_devices = None
    elif not args.skip_device_list:
        current_devices, device_snapshot_error = load_current_devices()
    if args.lock_state_snapshot:
        lock_states = read_json(Path(args.lock_state_snapshot))
        if not isinstance(lock_states, list):
            lock_state_error = f"lock-state snapshot missing or invalid: {args.lock_state_snapshot}"
            lock_states = None
    elif not args.skip_lock_state:
        lock_states, lock_state_error = load_current_lock_states()
    if not args.skip_launchability:
        launchability, launchability_error = load_launchability_snapshot(args.launchability_snapshot)
    status = build_status(
        args.readiness,
        run_inputs,
        current_devices=current_devices,
        device_snapshot_error=device_snapshot_error,
        lock_states=lock_states,
        lock_state_error=lock_state_error,
        launchability=launchability,
        launchability_error=launchability_error,
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(status, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"physical-device boundary status: {status['status']}")
    print(f"physical-device boundary status artifact: {output}")
    return 0 if status["ok"] else 1


def build_status(
    readiness_path: str,
    run_inputs: list[str],
    *,
    current_devices: list[dict[str, Any]] | None = None,
    device_snapshot_error: str | None = None,
    lock_states: list[dict[str, Any]] | None = None,
    lock_state_error: str | None = None,
    launchability: list[dict[str, Any]] | None = None,
    launchability_error: str | None = None,
) -> dict[str, Any]:
    readiness = read_json(Path(readiness_path))
    physical_blocker = physical_blocking_evidence(readiness)
    runs = [run for run in (read_run_summary(value) for value in run_inputs) if run is not None]
    latest_by_cell = latest_runs_by_cell(runs)
    missing_cells = missing_physical_cells(physical_blocker)
    actionable_cells = {
        cell: latest_by_cell[cell]
        for cell in missing_cells
        if cell in latest_by_cell
    }
    ok = isinstance(readiness, dict) and readiness.get("status") == "ready"
    current_device_preflight = physical_device_preflight(
        current_devices,
        error=device_snapshot_error,
    )
    current_lock_state_probe = advisory_lock_state_probe(
        lock_states,
        error=lock_state_error,
    )
    current_launchability_probe = launchability_probe(
        launchability,
        error=launchability_error,
    )
    finalize_summary = physical_finalize_summary(physical_blocker)
    evidence_window = physical_evidence_window(physical_blocker)
    plans = missing_cell_plans(
        missing_cells,
        latest_by_cell,
        physical_blocker.get("nextCommands", []) if isinstance(physical_blocker, dict) else [],
        current_device_preflight,
        current_lock_state_probe,
        finalize_failed_cells_by_name(physical_blocker),
    )
    return {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "status": "ready" if ok else "not-ready",
        "ok": ok,
        "readiness": {
            "path": readiness_path,
            "status": readiness.get("status") if isinstance(readiness, dict) else "missing",
        },
        "physicalBlockingEvidence": physical_blocker,
        "physicalFinalizeSummary": finalize_summary,
        "physicalEvidenceWindow": evidence_window,
        "missingCells": missing_cells,
        "currentDevicePreflight": current_device_preflight,
        "currentLockStateProbe": current_lock_state_probe,
        "currentLaunchabilityProbe": current_launchability_probe,
        "latestRuns": list(latest_by_cell.values()),
        "actionableCells": actionable_cells,
        "missingCellPlans": plans,
        "priorityActions": priority_actions(
            actionable_cells,
            plans,
            current_device_preflight,
            current_lock_state_probe,
            current_launchability_probe,
        ),
        "nextCommands": physical_blocker.get("nextCommands", []) if isinstance(physical_blocker, dict) else [],
    }


def physical_finalize_summary(physical_blocker: dict[str, Any]) -> dict[str, Any]:
    summary = physical_blocker.get("physicalFinalizeSummary")
    if not isinstance(summary, dict):
        return {}
    return {
        key: summary[key]
        for key in [
            "artifact",
            "status",
            "ok",
            "resolvedManifests",
            "skippedMissingInputs",
            "passedCells",
            "failedCells",
        ]
        if key in summary
    }


def physical_evidence_window(physical_blocker: dict[str, Any]) -> dict[str, Any]:
    window = physical_blocker.get("physicalEvidenceWindow")
    if not isinstance(window, dict):
        return {}
    return dict(window)


def physical_blocking_evidence(readiness: Any) -> dict[str, Any]:
    if not isinstance(readiness, dict):
        return {
            "name": "physical-device-boundaries",
            "status": "missing",
            "detail": "readiness artifact missing or invalid",
            "nextCommands": [],
        }
    for item in readiness.get("blockingEvidence", []):
        if isinstance(item, dict) and item.get("name") == "physical-device-boundaries":
            return item
    return {
        "name": "physical-device-boundaries",
        "status": "pass",
        "detail": "physical-device boundaries are not blocking readiness",
        "nextCommands": [],
    }


def missing_physical_cells(physical_blocker: dict[str, Any]) -> list[str]:
    structured_cells = missing_physical_cells_from_finalize_summary(physical_blocker)
    if structured_cells:
        return structured_cells
    detail = str(physical_blocker.get("detail") or "")
    cells = []
    for cell in [
        "foreground-ptt-audio",
        "lockscreen-apns-wake",
        "direct-quic-media",
        "fallback-relay-audio",
    ]:
        if cell in detail:
            cells.append(cell)
    return cells


def missing_physical_cells_from_finalize_summary(physical_blocker: dict[str, Any]) -> list[str]:
    summary = physical_blocker.get("physicalFinalizeSummary")
    if not isinstance(summary, dict):
        return []
    failed_cells = summary.get("failedCells")
    if not isinstance(failed_cells, list):
        return []
    cells: list[str] = []
    known_cells = {
        "foreground-ptt-audio",
        "lockscreen-apns-wake",
        "direct-quic-media",
        "fallback-relay-audio",
    }
    for item in failed_cells:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "")
        if name in known_cells and name not in cells:
            cells.append(name)
    return cells


def missing_cell_plans(
    missing_cells: list[str],
    latest_by_cell: dict[str, dict[str, Any]],
    next_commands: list[Any],
    current_device_preflight: dict[str, Any],
    current_lock_state_probe: dict[str, Any],
    finalize_failed_cells: dict[str, dict[str, Any]] | None = None,
) -> dict[str, dict[str, Any]]:
    commands_by_cell = next_commands_by_cell(next_commands)
    return {
        cell: {
            "cell": cell,
            "finalizeFailure": finalize_failed_cells.get(cell, {}) if finalize_failed_cells else {},
            "latestRun": latest_by_cell.get(cell),
            "currentDevicePreflight": current_device_preflight,
            "currentLockStateProbe": current_lock_state_probe,
            "operatorRequirements": operator_requirements_for_cell(cell),
            "nextCommand": commands_by_cell.get(cell),
            **lockscreen_wake_target_preflight(cell),
        }
        for cell in missing_cells
    }


def lockscreen_wake_target_preflight(cell: str) -> dict[str, Any]:
    if cell != "lockscreen-apns-wake":
        return {}
    return {
        "wakeTargetPreflightCommand": {
            "name": "verify-lockscreen-wake-target",
            "description": "Dry-run the backend PushToTalk APNs target lookup before locking the receiver or sending APNs.",
            "command": (
                'just ptt-apns-print-only <channel-id> https://staging.beepbeep.to '
                '<sender-handle> com.rounded.Turbo --insecure'
            ),
        }
    }


def finalize_failed_cells_by_name(physical_blocker: dict[str, Any]) -> dict[str, dict[str, Any]]:
    summary = physical_blocker.get("physicalFinalizeSummary")
    if not isinstance(summary, dict):
        return {}
    failed_cells = summary.get("failedCells")
    if not isinstance(failed_cells, list):
        return {}
    result: dict[str, dict[str, Any]] = {}
    for item in failed_cells:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "")
        if not name:
            continue
        result[name] = {
            "name": name,
            "reason": str(item.get("reason") or ""),
        }
    return result


def next_commands_by_cell(next_commands: list[Any]) -> dict[str, dict[str, Any]]:
    by_cell: dict[str, dict[str, Any]] = {}
    for command in next_commands:
        if not isinstance(command, dict):
            continue
        name = str(command.get("name") or "")
        raw_command = str(command.get("command") or "")
        for cell in [
            "foreground-ptt-audio",
            "lockscreen-apns-wake",
            "direct-quic-media",
            "fallback-relay-audio",
        ]:
            if cell in name or cell in raw_command:
                by_cell[cell] = command
    return by_cell


def operator_requirements_for_cell(cell: str) -> list[dict[str, str]]:
    common = [
        {
            "name": "two-visible-paired-physical-devices",
            "description": "Both paired physical iOS devices are visible to devicectl; a stale disconnected tunnel state is a warning unless commands cannot acquire a tunnel.",
        },
        {
            "name": "devices-unlocked-before-launch",
            "description": "Unlock both devices before launch/profile application; lock failures are confirmed by launch diagnostics.",
        },
    ]
    by_cell = {
        "foreground-ptt-audio": [
            {
                "name": "foreground-ptt-transmit",
                "description": "Keep both apps foregrounded and perform a real PTT transmit long enough to capture receiver playback.",
            }
        ],
        "direct-quic-media": [
            {
                "name": "direct-quic-launch-profile",
                "description": "Run with the direct-quic launch profile so diagnostics prove Direct QUIC configuration context.",
            },
            {
                "name": "direct-quic-ptt-transmit",
                "description": "Perform a real PTT transmit while Direct QUIC is active and receiver playback is audible.",
            },
        ],
        "fallback-relay-audio": [
            {
                "name": "fallback-relay-launch-profile",
                "description": "Run with the fallback-relay launch profile so diagnostics prove relay/fallback configuration context.",
            },
            {
                "name": "fallback-relay-ptt-transmit",
                "description": "Perform a real PTT transmit while relay media is forced and receiver playback is audible.",
            },
        ],
        "lockscreen-apns-wake": [
            {
                "name": "receiver-background-or-locked",
                "description": "Put the receiver in background or locked state before sending the wake.",
            },
            {
                "name": "wake-channel-id",
                "description": "Provide the live channel id with --wake-channel-id, or use --allow-manual-wake only when wake delivery is triggered externally.",
            },
            {
                "name": "wake-sender-handle",
                "description": "Provide the sender handle with --wake-handle for the built-in PushToTalk APNs sender.",
            },
            {
                "name": "lockscreen-playback",
                "description": "Verify the receiver wakes and schedules playback while backgrounded or locked.",
            },
        ],
    }
    return common + by_cell.get(cell, [])


def priority_actions(
    actionable_cells: dict[str, dict[str, Any]],
    missing_cell_plans: dict[str, dict[str, Any]],
    current_device_preflight: dict[str, Any],
    current_lock_state_probe: dict[str, Any] | None = None,
    current_launchability_probe: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    actions: list[dict[str, Any]] = []
    for blocker in current_device_preflight.get("blockers", []):
        actions.append(
            {
                "kind": "resolve-device-preflight",
                "cell": None,
                "summary": str(blocker),
                "remediation": "Fix the physical-device preflight before rerunning target-cell collection.",
            }
        )
    for cell, run in actionable_cells.items():
        for failure in run.get("launchFailures", []):
            if not isinstance(failure, dict):
                continue
            device = str(failure.get("device") or failure.get("udid") or "device")
            reason = str(failure.get("reason") or "unknown")
            remediation = failure.get("remediation") or "Fix this launch failure before rerunning the target cell."
            probe_status = lock_state_probe_status_for_failure(current_lock_state_probe, failure)
            if reason == "device-disconnected" and probe_status == "reachable":
                remediation = (
                    "The current advisory lock-state probe can reach this device, so the previous "
                    "CoreDevice disconnect may be stale. Rerun the target cell; if it disconnects "
                    "again, reconnect the device or stabilize the local-network/CoreDevice connection."
                )
            action = {
                "kind": "resolve-launch-failure",
                "cell": cell,
                "device": device,
                "reason": reason,
                "summary": f"{device}: {reason}",
                "remediation": remediation,
            }
            if reason == "locked":
                action["verificationCommand"] = "just device-launch-connected-json"
                action["verificationArtifact"] = "/tmp/turbo-device-launch-connected-current.json"
                launchability_status = launchability_probe_status_for_failure(
                    current_launchability_probe,
                    failure,
                )
                if launchability_status:
                    action["currentLaunchabilityProbe"] = launchability_status
                    if launchability_status not in {reason, "launchable"}:
                        action["currentLaunchabilityMismatch"] = True
                        action["remediation"] = (
                            f"The latest launchability probe now reports {launchability_status} "
                            f"for this device, while the target run recorded {reason}. Resolve "
                            "the current launchability failure and rerun the target cell so the "
                            "physical proof uses fresh device state."
                        )
            if probe_status:
                action["currentLockStateProbe"] = probe_status
            actions.append(
                action
            )
    actions.extend(
        current_launchability_failure_actions(
            current_launchability_probe,
            current_lock_state_probe,
            actions,
        )
    )
    for cell, plan in missing_cell_plans.items():
        latest_run = plan.get("latestRun")
        next_command = plan.get("nextCommand")
        if latest_run is None:
            action = {
                "kind": "collect-missing-cell",
                "cell": cell,
                "summary": f"No latest target run exists for {cell}.",
                "requirements": [
                    requirement.get("name")
                    for requirement in plan.get("operatorRequirements", [])
                    if isinstance(requirement, dict)
                ],
                "command": next_command.get("command") if isinstance(next_command, dict) else None,
            }
            wake_target_preflight_command = plan.get("wakeTargetPreflightCommand")
            if not isinstance(wake_target_preflight_command, dict):
                wake_target_preflight_command = lockscreen_wake_target_preflight(cell).get(
                    "wakeTargetPreflightCommand"
                )
            if isinstance(wake_target_preflight_command, dict):
                action["wakeTargetPreflightCommand"] = wake_target_preflight_command
            finalize_failure = plan.get("finalizeFailure")
            if isinstance(finalize_failure, dict) and finalize_failure:
                action["finalizeFailure"] = finalize_failure
            actions.append(action)
            continue
        if not run_has_launch_failures(latest_run):
            target_proof = latest_run.get("targetCellProof") if isinstance(latest_run, dict) else {}
            if not isinstance(target_proof, dict):
                target_proof = {}
            action = {
                "kind": "rerun-missing-cell",
                "cell": cell,
                "summary": f"Rerun {cell} after satisfying the listed operator requirements.",
                "requirements": [
                    requirement.get("name")
                    for requirement in plan.get("operatorRequirements", [])
                    if isinstance(requirement, dict)
                ],
                "missingEvidence": target_proof.get("missingEvidence")
                if isinstance(target_proof.get("missingEvidence"), list)
                else [],
                "missingContext": target_proof.get("missingContext")
                if isinstance(target_proof.get("missingContext"), list)
                else [],
                "command": next_command.get("command") if isinstance(next_command, dict) else None,
            }
            wake_target_preflight_command = plan.get("wakeTargetPreflightCommand")
            if not isinstance(wake_target_preflight_command, dict):
                wake_target_preflight_command = lockscreen_wake_target_preflight(cell).get(
                    "wakeTargetPreflightCommand"
                )
            if isinstance(wake_target_preflight_command, dict):
                action["wakeTargetPreflightCommand"] = wake_target_preflight_command
            send_wake_apns_result = latest_run.get("sendWakeApnsResult")
            if cell == "lockscreen-apns-wake" and isinstance(send_wake_apns_result, dict) and send_wake_apns_result:
                action["sendWakeApnsResult"] = send_wake_apns_result
                diagnosis = wake_send_diagnosis(send_wake_apns_result)
                if diagnosis:
                    action["wakeSendDiagnosis"] = diagnosis
            finalize_failure = plan.get("finalizeFailure")
            if isinstance(finalize_failure, dict) and finalize_failure:
                action["finalizeFailure"] = finalize_failure
            actions.append(action)
    return actions


def current_launchability_failure_actions(
    current_launchability_probe: dict[str, Any] | None,
    current_lock_state_probe: dict[str, Any] | None,
    existing_actions: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    if not isinstance(current_launchability_probe, dict):
        return []
    devices = current_launchability_probe.get("devices")
    if not isinstance(devices, list):
        return []
    actions: list[dict[str, Any]] = []
    for device in devices:
        if not isinstance(device, dict) or device.get("ok") is True:
            continue
        name = str(device.get("name") or device.get("udid") or "device")
        udid = str(device.get("udid") or "")
        reason = str(device.get("reason") or "unknown")
        if launchability_action_already_exists(existing_actions + actions, name, udid, reason):
            continue
        failure = enrich_launch_failure(
            {
                "device": name,
                "udid": udid,
                "reason": reason,
                "message": str(device.get("message") or ""),
            }
        )
        action: dict[str, Any] = {
            "kind": "resolve-current-launchability-failure",
            "cell": None,
            "device": name,
            "reason": reason,
            "summary": f"{name}: {reason}",
            "remediation": failure.get("remediation")
            or "Fix this launchability failure before collecting physical target cells.",
            "verificationCommand": "just device-launch-connected-json",
            "verificationArtifact": str(current_launchability_probe.get("artifact") or DEFAULT_LAUNCHABILITY),
            "currentLaunchabilityProbe": reason,
        }
        probe_status = lock_state_probe_status_for_failure(current_lock_state_probe, failure)
        if probe_status:
            action["currentLockStateProbe"] = probe_status
        actions.append(action)
    return actions


def launchability_action_already_exists(
    actions: list[dict[str, Any]],
    device_name: str,
    udid: str,
    reason: str,
) -> bool:
    for action in actions:
        if not isinstance(action, dict):
            continue
        action_device = str(action.get("device") or "")
        action_reason = str(action.get("reason") or "")
        if action_reason != reason:
            continue
        if action_device and action_device in {device_name, udid}:
            return True
    return False


def lock_state_probe_status_for_failure(
    current_lock_state_probe: dict[str, Any] | None,
    failure: dict[str, Any],
) -> str | None:
    if not isinstance(current_lock_state_probe, dict):
        return None
    devices = current_lock_state_probe.get("devices")
    if not isinstance(devices, list):
        return None
    failure_udid = str(failure.get("udid") or "")
    failure_device = str(failure.get("device") or "")
    for device in devices:
        if not isinstance(device, dict):
            continue
        candidates = {str(device.get("udid") or ""), str(device.get("name") or "")}
        if failure_udid not in candidates and failure_device not in candidates:
            continue
        if device.get("ok") is True:
            return "reachable"
        return "failed"
    return None


def launchability_probe_status_for_failure(
    current_launchability_probe: dict[str, Any] | None,
    failure: dict[str, Any],
) -> str | None:
    if not isinstance(current_launchability_probe, dict):
        return None
    devices = current_launchability_probe.get("devices")
    if not isinstance(devices, list):
        return None
    failure_udid = str(failure.get("udid") or "")
    failure_device = str(failure.get("device") or "")
    for device in devices:
        if not isinstance(device, dict):
            continue
        candidates = {str(device.get("udid") or ""), str(device.get("name") or "")}
        if failure_udid not in candidates and failure_device not in candidates:
            continue
        if device.get("ok") is True:
            return "launchable"
        reason = str(device.get("reason") or "")
        return reason or "failed"
    return None


def run_has_launch_failures(run: Any) -> bool:
    return isinstance(run, dict) and bool(run.get("launchFailures"))


def wake_send_diagnosis(send_result: dict[str, Any]) -> dict[str, str]:
    if send_result.get("ok") is True:
        return {
            "kind": "sent",
            "summary": "PushToTalk APNs wake send succeeded; remaining proof must come from receiver wake/playback diagnostics.",
            "remediation": "Keep the receiver backgrounded or locked and collect receiver wake, activation, and playback evidence.",
        }
    stage = str(send_result.get("stage") or "")
    status = int(send_result.get("status") or 0)
    body = str(send_result.get("body") or "")
    error = str(send_result.get("error") or "")
    combined = f"{error}\n{body}".lower()
    if stage == "backend-push-target" and status in {401, 403} and "not a channel member" in combined:
        return {
            "kind": "not-channel-member",
            "summary": "The sender handle is not authorized as a member of the supplied channel, so no APNs wake target was produced.",
            "remediation": "Rerun with a live channel id and a sender handle that is a member of that channel.",
        }
    if stage == "backend-push-target" and status == 404:
        return {
            "kind": "push-target-not-found",
            "summary": "The backend did not find a wake-capable PushToTalk target for the supplied channel and sender.",
            "remediation": "Open the receiver app in the target channel long enough to publish its push target, then rerun with that live channel id and sender handle.",
        }
    if stage == "backend-push-target":
        return {
            "kind": "backend-push-target-failed",
            "summary": "The backend push-target lookup failed before APNs delivery could be attempted.",
            "remediation": "Fix the channel id, sender handle, membership, or backend push-target route before judging lock-screen wake delivery.",
        }
    return {}


def read_run_summary(value: str) -> dict[str, Any] | None:
    if not value:
        return None
    path = Path(value)
    if path.is_dir():
        path = path / "physical-device-boundary-collect.json"
    payload = read_json(path)
    if not isinstance(payload, dict):
        return None
    target_cell = payload.get("targetCell") or payload.get("targetCellProof", {}).get("name")
    launch_failures = payload.get("launchFailures") if isinstance(payload.get("launchFailures"), list) else []
    step_launch_failures = launch_failures_from_steps(payload.get("steps"))
    if step_launch_failures:
        launch_failures = physical_device_boundary_collect.dedupe_failure_details(
            launch_failures + step_launch_failures
        )
    launch_failures = [enrich_launch_failure(failure) for failure in launch_failures]
    return {
        "path": str(path),
        "outputDir": payload.get("outputDir"),
        "status": payload.get("status"),
        "ok": payload.get("ok") is True,
        "targetCell": target_cell,
        "generatedAt": payload.get("generatedAt"),
        "runStartedAt": payload.get("runStartedAt"),
        "operatorBlockers": payload.get("operatorBlockers") if isinstance(payload.get("operatorBlockers"), list) else [],
        "launchFailures": launch_failures,
        "currentDevicePreflight": payload.get("currentDevicePreflight")
        if isinstance(payload.get("currentDevicePreflight"), dict)
        else {},
        "currentLaunchabilityPreflight": payload.get("currentLaunchabilityPreflight")
        if isinstance(payload.get("currentLaunchabilityPreflight"), dict)
        else {},
        "apnsCredentialPreflight": payload.get("apnsCredentialPreflight")
        if isinstance(payload.get("apnsCredentialPreflight"), dict)
        else {},
        "wakeApnsSent": payload.get("wakeApnsSent") is True,
        "sendWakeApnsResult": send_wake_apns_result_from_steps(payload.get("steps")),
        "targetCellProof": payload.get("targetCellProof") if isinstance(payload.get("targetCellProof"), dict) else {},
        "nextCommands": payload.get("nextCommands") if isinstance(payload.get("nextCommands"), list) else [],
        "steps": compact_steps(payload.get("steps")),
    }


def launch_failures_from_steps(steps: Any) -> list[dict[str, str]]:
    if not isinstance(steps, list):
        return []
    for step in steps:
        if isinstance(step, dict) and step.get("name") == "device-launch-profile":
            return physical_device_boundary_collect.classify_launch_failure_details(step)
    return []


def send_wake_apns_result_from_steps(steps: Any) -> dict[str, Any]:
    if not isinstance(steps, list):
        return {}
    for step in steps:
        if not isinstance(step, dict) or step.get("name") != "send-wake-apns":
            continue
        if step.get("skipped") is True:
            result: dict[str, Any] = {
                "ok": False,
                "status": "skipped",
            }
            if step.get("reason"):
                result["reason"] = str(step.get("reason"))
            return result
        stdout = str(step.get("stdout") or "").strip()
        if not stdout:
            return {
                "ok": step.get("ok") is True,
                "status": "missing-output",
            }
        payload = parse_json_object(stdout)
        if not isinstance(payload, dict):
            return {
                "ok": False,
                "status": "unparseable-output",
                "error": "send-wake-apns stdout did not contain a JSON object",
            }
        result = {
            key: payload[key]
            for key in [
                "ok",
                "status",
                "stage",
                "channelId",
                "handle",
                "error",
                "body",
            ]
            if key in payload
        }
        if isinstance(result.get("body"), str):
            result["body"] = compact_text(str(result["body"]), limit=500)
        if "ok" not in result:
            result["ok"] = step.get("ok") is True
        return result
    return {}


def parse_json_object(value: str) -> Any:
    decoder = json.JSONDecoder()
    stripped = value.strip()
    try:
        parsed, _ = decoder.raw_decode(stripped)
        return parsed
    except json.JSONDecodeError:
        pass
    for index, char in enumerate(stripped):
        if char != "{":
            continue
        try:
            parsed, _ = decoder.raw_decode(stripped[index:])
            return parsed
        except json.JSONDecodeError:
            continue
    return None


def compact_steps(steps: Any) -> list[dict[str, Any]]:
    if not isinstance(steps, list):
        return []
    return [compact_step(step) for step in steps if isinstance(step, dict)]


def compact_step(step: dict[str, Any]) -> dict[str, Any]:
    stdout = str(step.get("stdout") or "")
    stderr = str(step.get("stderr") or "")
    result: dict[str, Any] = {
        "name": step.get("name"),
        "ok": step.get("ok"),
        "exitCode": step.get("exitCode"),
    }
    for key in ["skipped", "reason", "seconds", "elapsedSeconds"]:
        if key in step:
            result[key] = step.get(key)
    if step.get("command"):
        result["command"] = step.get("command")
    if stdout or stderr:
        result["outputSummary"] = {
            "stdoutBytes": len(stdout),
            "stderrBytes": len(stderr),
            "diagnosticLines": diagnostic_lines(stdout, stderr),
        }
    return result


def diagnostic_lines(stdout: str, stderr: str) -> list[str]:
    patterns = [
        "== ",
        "ERROR",
        "Error",
        "error",
        "failed",
        "Failed",
        "Locked",
        "locked",
        "Unable",
        "unable",
        "disconnected",
        "run-connected failed",
        "physical-device boundary",
        "passing cells:",
        "incomplete cells:",
    ]
    lines: list[str] = []
    for source in [stderr, stdout]:
        for line in source.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            if any(pattern in stripped for pattern in patterns):
                lines.append(stripped)
    return dedupe_strings(lines)[:40]


def compact_text(value: str, *, limit: int) -> str:
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 16)] + "...[truncated]"


def enrich_launch_failure(failure: dict[str, str]) -> dict[str, str]:
    reason = failure.get("reason", "")
    remediation_by_reason = {
        "locked": (
            "Unlock this device, keep it awake, and rerun the target cell so "
            "the launch profile can be applied."
        ),
        "device-disconnected": (
            "Reconnect this device or stabilize the local-network/CoreDevice connection, "
            "then rerun the target cell."
        ),
        "device-unavailable": (
            "Make this device available to CoreDevice by reconnecting it, unlocking it, "
            "and waiting for devicectl to see it before rerunning the target cell."
        ),
        "launch-failed": (
            "Inspect the saved launch step output for this device, fix the launch failure, "
            "and rerun the target cell."
        ),
        "device-command-failed": (
            "Inspect the saved launch step output for this device; the command failed "
            "without a more specific classified reason."
        ),
    }
    if "remediation" in failure:
        return failure
    remediation = remediation_by_reason.get(
        reason,
        "Inspect the saved launch step output for this device before rerunning the target cell.",
    )
    return {**failure, "remediation": remediation}


def dedupe_strings(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def latest_runs_by_cell(runs: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    by_cell: dict[str, dict[str, Any]] = {}
    for run in runs:
        cell = run.get("targetCell")
        if not isinstance(cell, str) or not cell:
            continue
        existing = by_cell.get(cell)
        if existing is None or str(run.get("generatedAt") or "") >= str(existing.get("generatedAt") or ""):
            by_cell[cell] = run
    return by_cell


def load_current_devices() -> tuple[list[dict[str, Any]] | None, str | None]:
    try:
        result = subprocess.run(
            ["python3", "tools/scripts/device_app.py", "list", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"device list failed: {exc}"
    if result.returncode != 0:
        stderr = result.stderr.strip()
        return None, f"device list exited {result.returncode}: {stderr}"
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return None, f"device list JSON invalid: {exc}"
    if not isinstance(payload, list):
        return None, "device list JSON was not a list"
    return [device for device in payload if isinstance(device, dict)], None


def load_current_lock_states() -> tuple[list[dict[str, Any]] | None, str | None]:
    try:
        result = subprocess.run(
            ["python3", "tools/scripts/device_app.py", "--timeout", "20", "lock-state-connected", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"lock-state probe failed: {exc}"
    if result.returncode != 0:
        stderr = result.stderr.strip()
        stdout = result.stdout.strip()
        detail = stderr or stdout
        return None, f"lock-state probe exited {result.returncode}: {detail}"
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return None, f"lock-state JSON invalid: {exc}"
    if not isinstance(payload, list):
        return None, "lock-state JSON was not a list"
    return [item for item in payload if isinstance(item, dict)], None


def load_launchability_snapshot(path: str) -> tuple[list[dict[str, Any]] | None, str | None]:
    if not path:
        return None, "launchability snapshot path was empty"
    snapshot = Path(path)
    if not snapshot.exists():
        return None, f"launchability snapshot missing: {path}"
    payload = read_json(snapshot)
    if not isinstance(payload, list):
        return None, f"launchability snapshot missing or invalid: {path}"
    return [item for item in payload if isinstance(item, dict)], None


def physical_device_preflight(
    devices: list[dict[str, Any]] | None,
    *,
    error: str | None = None,
) -> dict[str, Any]:
    if devices is None:
        return {
            "status": "unknown",
            "ok": False,
            "error": error or "current physical-device list was not collected",
            "devices": [],
            "blockers": ["current connected physical-device state is unknown"],
        }
    connected = [
        device
        for device in devices
        if str(device.get("state") or "").casefold() == "connected"
    ]
    blockers: list[str] = []
    warnings: list[str] = []
    if len(devices) < 2:
        blockers.append("fewer than two paired physical iOS devices are visible")
    disconnected = [
        {
            "name": str(device.get("name") or ""),
            "udid": str(device.get("udid") or ""),
            "state": str(device.get("state") or ""),
        }
        for device in devices
        if str(device.get("state") or "").casefold() != "connected"
    ]
    if disconnected:
        warnings.append(
            "non-connected devices: "
            + ", ".join(
                f"{device['name'] or device['udid']}={device['state'] or 'unknown'}"
                for device in disconnected
            )
        )
    return {
        "status": "pass" if not blockers else "fail",
        "ok": not blockers,
        "pairedPhysicalDeviceCount": len(devices),
        "connectedPhysicalDeviceCount": len(connected),
        "commandReady": len(connected) >= 2,
        "commandReadinessStatus": command_readiness_status(len(connected)),
        "devices": [
            {
                "name": str(device.get("name") or ""),
                "udid": str(device.get("udid") or ""),
                "model": str(device.get("model") or ""),
                "osVersion": str(device.get("os_version") or device.get("osVersion") or ""),
                "transport": str(device.get("transport") or ""),
                "state": str(device.get("state") or ""),
            }
            for device in devices
        ],
        "blockers": blockers,
        "warnings": warnings,
        "operatorNote": (
            "Both physical devices must be visible and unlocked before target-cell launch. "
            "A non-connected tunnel state can be stale because devicectl may acquire the tunnel during the command; "
            "current command readiness and lock state are confirmed by launch diagnostics, not by this device-list preflight."
        ),
    }


def command_readiness_status(connected_count: int) -> str:
    if connected_count >= 2:
        return "ready"
    if connected_count == 1:
        return "partial"
    return "none"


def advisory_lock_state_probe(
    lock_states: list[dict[str, Any]] | None,
    *,
    error: str | None = None,
) -> dict[str, Any]:
    note = (
        "devicectl lockState is an advisory CoreDevice reachability and unlocked-since-boot probe. "
        "Current foreground-launch unlock is still confirmed by launch diagnostics because this "
        "devicectl JSON may not expose a current locked/unlocked field."
    )
    if lock_states is None:
        return {
            "status": "unknown",
            "ok": False,
            "advisoryOnly": True,
            "error": error or "current lock-state probe was not collected",
            "devices": [],
            "operatorNote": note,
        }
    reachable = [item for item in lock_states if item.get("ok") is True]
    failed = [item for item in lock_states if item.get("ok") is not True]
    current_known = [item for item in reachable if item.get("currentLockStateKnown") is True]
    return {
        "status": "pass" if not failed else "partial",
        "ok": not failed,
        "advisoryOnly": True,
        "reachablePhysicalDeviceCount": len(reachable),
        "failedPhysicalDeviceCount": len(failed),
        "currentLockStateKnownCount": len(current_known),
        "devices": [compact_lock_state(item) for item in lock_states],
        "operatorNote": note,
    }


def compact_lock_state(item: dict[str, Any]) -> dict[str, Any]:
    device = item.get("device") if isinstance(item.get("device"), dict) else {}
    return {
        "name": str(device.get("name") or ""),
        "udid": str(device.get("udid") or ""),
        "state": str(device.get("state") or ""),
        "ok": item.get("ok") is True,
        "passcodeRequired": item.get("passcodeRequired"),
        "unlockedSinceBoot": item.get("unlockedSinceBoot"),
        "currentLockStateKnown": item.get("currentLockStateKnown") is True,
        "currentLocked": item.get("currentLocked"),
        "rawResultKeys": item.get("rawResultKeys") if isinstance(item.get("rawResultKeys"), list) else [],
        "error": item.get("error") if item.get("ok") is not True else None,
    }


def launchability_probe(
    launchability: list[dict[str, Any]] | None,
    *,
    error: str | None = None,
) -> dict[str, Any]:
    if launchability is None:
        return {
            "status": "unknown",
            "ok": False,
            "error": error or "current launchability probe was not collected",
            "artifact": DEFAULT_LAUNCHABILITY,
            "devices": [],
            "operatorNote": (
                "Run `just device-launch-connected-json` after unlocking devices to record "
                "cheap launchability evidence before target-cell collection."
            ),
        }
    launchable = [item for item in launchability if item.get("ok") is True]
    failed = [item for item in launchability if item.get("ok") is not True]
    reasons = sorted(
        {
            str(item.get("reason") or "unknown")
            for item in failed
        }
    )
    return {
        "status": "pass" if not failed else "fail",
        "ok": not failed,
        "artifact": DEFAULT_LAUNCHABILITY,
        "launchablePhysicalDeviceCount": len(launchable),
        "failedPhysicalDeviceCount": len(failed),
        "failureReasons": reasons,
        "devices": [compact_launchability(item) for item in launchability],
        "operatorNote": (
            "This probe launches the already-installed app without rebuilding. "
            "A passing probe is not physical boundary proof; it only proves devices are launchable."
        ),
    }


def compact_launchability(item: dict[str, Any]) -> dict[str, Any]:
    device = item.get("device") if isinstance(item.get("device"), dict) else {}
    return {
        "name": str(device.get("name") or ""),
        "udid": str(device.get("udid") or ""),
        "state": str(device.get("state") or ""),
        "ok": item.get("ok") is True,
        "reason": str(item.get("reason") or ""),
        "message": str(item.get("message") or ""),
        "launchJson": str(item.get("launchJson") or ""),
    }


def read_json(path: Path) -> Any:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
