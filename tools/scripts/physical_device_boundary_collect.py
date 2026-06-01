#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from physical_device_boundary_proof import REQUIRED_CELLS


DEFAULT_OUTPUT_ROOT = Path("/tmp/turbo-physical-device-boundary-runs")
DEFAULT_MANIFEST_OUTPUT = "/tmp/turbo-physical-device-boundaries-manifest.json"
DEFAULT_PROOF_OUTPUT = "/tmp/turbo-physical-device-boundaries.json"

TARGET_CELL_LAUNCH_PROFILES = {
    "foreground-ptt-audio": "current",
    "lockscreen-apns-wake": "current",
    "direct-quic-media": "direct-quic",
    "fallback-relay-audio": "fallback-relay",
}

TARGET_CELL_OPERATOR_STEPS = {
    "foreground-ptt-audio": [
        "Keep both physical devices unlocked and foregrounded.",
        "Join the target conversation on both devices.",
        "Hold and release the PTT control long enough to capture first audio on the receiver.",
    ],
    "lockscreen-apns-wake": [
        "Put the receiver in background or locked state before the APNs send step.",
        "Send the PushToTalk APNs wake with --send-wake-apns.",
        "Verify lock-screen playback before diagnostics collection.",
    ],
    "direct-quic-media": [
        "Keep both devices foregrounded unless the run is intentionally combining cells.",
        "Confirm the app is launched with the direct-quic profile.",
        "Hold and release the PTT control while Direct QUIC is active.",
    ],
    "fallback-relay-audio": [
        "Keep both devices foregrounded unless the run is intentionally combining cells.",
        "Confirm the app is launched with the fallback-relay profile.",
        "Hold and release the PTT control while relay transport is forced.",
    ],
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Collect physical-device diagnostics, derive the boundary manifest, "
            "and run the physical-device cutover proof."
        )
    )
    parser.add_argument("handles", nargs="*", help="Handles to pass to reliability intake.")
    parser.add_argument("--base-url", default="https://staging.beepbeep.to")
    parser.add_argument("--output-dir", default="")
    parser.add_argument("--artifact", action="append", default=[], help="Existing diagnostics artifact to include.")
    parser.add_argument(
        "--device",
        action="append",
        default=[],
        metavar="HANDLE=DEVICE_ID",
        help="Exact backend diagnostics device mapping for reliability intake.",
    )
    parser.add_argument(
        "--physical-device",
        action="append",
        default=[],
        help="Physical device id/name/UDID to put in the proof manifest. Repeat for sender and receiver.",
    )
    parser.add_argument("--incident-id", default="")
    parser.add_argument("--backend-timeout", type=int, default=8)
    parser.add_argument("--telemetry-hours", type=int, default=2)
    parser.add_argument("--telemetry-limit", type=int, default=500)
    parser.add_argument("--include-heartbeats", action="store_true")
    parser.add_argument("--no-telemetry", action="store_true")
    parser.add_argument("--compact", action="store_true")
    parser.add_argument("--insecure", action="store_true")
    parser.add_argument("--skip-device-diagnostics", action="store_true")
    parser.add_argument("--skip-intake", action="store_true")
    parser.add_argument("--skip-launch", action="store_true")
    parser.add_argument(
        "--continue-after-launch-failure",
        action="store_true",
        help="Continue operator-timed interaction steps even when the debug launch profile fails.",
    )
    parser.add_argument(
        "--target-cell",
        choices=REQUIRED_CELLS,
        default="",
        help="Physical boundary cell this collection run is intended to prove.",
    )
    parser.add_argument(
        "--launch-profile",
        choices=("current", "direct-quic", "fallback-relay"),
        default="current",
        help="Optional debug launch profile to apply to every connected physical device before collecting diagnostics.",
    )
    parser.add_argument(
        "--allow-profile-mismatch",
        action="store_true",
        help="Allow a target cell to run with a non-default launch profile; the proof still validates diagnostic context anchors.",
    )
    parser.add_argument(
        "--allow-manual-wake",
        action="store_true",
        help="Allow a lock-screen wake target run without the built-in APNs sender when wake delivery is triggered externally.",
    )
    parser.add_argument("--include-crash-logs", action="store_true")
    parser.add_argument("--include-sysdiagnose", action="store_true")
    parser.add_argument(
        "--pre-collect-wait-seconds",
        type=float,
        default=0.0,
        help="Wait before diagnostics collection, for operator-driven physical interaction after launch.",
    )
    parser.add_argument("--send-wake-apns", action="store_true")
    parser.add_argument("--wake-channel-id", default="", help="Backend channel id for the PushToTalk APNs wake cell.")
    parser.add_argument("--wake-handle", default="", help="Sender handle for the PushToTalk APNs wake cell.")
    parser.add_argument("--wake-bundle-id", default="com.rounded.Turbo")
    parser.add_argument(
        "--post-wake-wait-seconds",
        type=float,
        default=8.0,
        help="Wait after sending APNs before collecting diagnostics.",
    )
    parser.add_argument("--manifest-output", default=DEFAULT_MANIFEST_OUTPUT)
    parser.add_argument("--proof-output", default=DEFAULT_PROOF_OUTPUT)
    parser.add_argument("--summary-output", default="")
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    run_started_at = utc_now()
    repo_root = Path(__file__).resolve().parents[2]
    output_dir = resolve_output_dir(args)
    output_dir.mkdir(parents=True, exist_ok=True)
    collection_plan = resolve_collection_plan(args)
    launch_profile = collection_plan["launchProfile"]
    manifest_output, proof_output = resolve_proof_outputs(args, output_dir)

    steps: list[dict[str, Any]] = []
    artifact_paths = existing_paths(args.artifact)
    operator_blockers: list[str] = []
    launch_failures: list[dict[str, str]] = []
    skip_interaction_steps = False
    skip_launch_steps = False
    wake_apns_sent = False
    current_device_preflight: dict[str, Any] = {"status": "not-collected", "ok": None}
    current_launchability_preflight: dict[str, Any] = {"status": "not-collected", "ok": None}
    apns_credential_preflight: dict[str, Any] = {"status": "not-collected", "ok": None}

    if should_collect_device_preflight(args, launch_profile):
        step = run_step(
            "device-list-preflight",
            [
                sys.executable,
                str(repo_root / "tools" / "scripts" / "device_app.py"),
                "list",
                "--json",
            ],
        )
        steps.append(step)
        current_device_preflight = current_device_preflight_from_step(step)
        if current_device_preflight.get("ok") is not True:
            operator_blockers.extend(current_device_preflight.get("blockers", []))
            if args.target_cell and not args.continue_after_launch_failure:
                skip_launch_steps = True
                skip_interaction_steps = True
                steps.append(
                    skipped_step(
                        "target-cell-interaction",
                        "current physical-device preflight failed; connect and unlock both devices or pass --continue-after-launch-failure to keep the timed interaction window",
                    )
                )

    if not skip_launch_steps and should_collect_launchability_preflight(args, launch_profile):
        launchability_output = output_dir / "device-launchability-preflight.json"
        step = run_step(
            "device-launchability-preflight",
            [
                sys.executable,
                str(repo_root / "tools" / "scripts" / "device_app.py"),
                "launch-connected",
                "--terminate-existing",
                "--continue-on-device-error",
                "--output",
                str(launchability_output),
            ],
        )
        steps.append(step)
        current_launchability_preflight = launchability_preflight_from_file(launchability_output, step)
        launchability_blockers = launchability_preflight_blockers(current_launchability_preflight)
        if launchability_blockers:
            operator_blockers.extend(launchability_blockers)
            launch_failures.extend(launchability_failure_details(current_launchability_preflight))
            if args.target_cell and not args.continue_after_launch_failure:
                skip_launch_steps = True
                skip_interaction_steps = True
                steps.append(
                    skipped_step(
                        "target-cell-interaction",
                        "device launchability preflight failed; unlock/reconnect devices or pass --continue-after-launch-failure to keep the timed interaction window",
                    )
                )

    if not skip_launch_steps and not args.skip_launch and launch_profile != "current":
        step = run_step(
            "device-launch-profile",
            [
                sys.executable,
                str(repo_root / "tools" / "scripts" / "device_app.py"),
                "run-connected",
                "--terminate-existing",
                "--continue-on-device-error",
                *launch_profile_environment(launch_profile),
            ],
        )
        steps.append(step)
        if not step["ok"]:
            operator_blockers.extend(classify_launch_failure(step))
            launch_failures.extend(classify_launch_failure_details(step))
            if args.target_cell and not args.continue_after_launch_failure:
                skip_interaction_steps = True
                steps.append(
                    skipped_step(
                        "target-cell-interaction",
                        "debug launch profile failed; unlock devices or pass --continue-after-launch-failure to keep the timed interaction window",
                    )
                )

    if args.pre_collect_wait_seconds > 0 and not skip_interaction_steps:
        steps.append(wait_step("pre-collect-wait", args.pre_collect_wait_seconds))

    if args.send_wake_apns and not skip_interaction_steps:
        step = run_step(
            "wake-apns-credential-preflight",
            [
                sys.executable,
                str(repo_root / "tools" / "scripts" / "send_ptt_apns.py"),
                "--check-credentials",
            ],
        )
        steps.append(step)
        apns_credential_preflight = apns_credential_preflight_from_step(step)
        if apns_credential_preflight.get("ok") is not True:
            operator_blockers.extend(apns_credential_blockers(apns_credential_preflight))
            if args.target_cell and not args.continue_after_launch_failure:
                skip_interaction_steps = True
                steps.append(
                    skipped_step(
                        "send-wake-apns",
                        "APNs credential preflight failed; set APNs signing environment before sending the wake",
                    )
                )

    if args.send_wake_apns and not skip_interaction_steps:
        if not args.wake_channel_id.strip() or not args.wake_handle.strip():
            raise SystemExit("--send-wake-apns requires --wake-channel-id and --wake-handle")
        step = run_step(
            "send-wake-apns",
            [
                sys.executable,
                str(repo_root / "tools" / "scripts" / "send_ptt_apns.py"),
                "--base-url",
                args.base_url,
                "--handle",
                args.wake_handle,
                "--channel-id",
                args.wake_channel_id,
                "--bundle-id",
                args.wake_bundle_id,
                *flag("--insecure", args.insecure),
            ],
        )
        steps.append(step)
        wake_apns_sent = step["ok"]
        if args.post_wake_wait_seconds > 0:
            steps.append(wait_step("post-wake-wait", args.post_wake_wait_seconds))

    if not args.skip_device_diagnostics:
        device_output_dir = output_dir / "device-diagnostics"
        step = run_step(
            "device-diagnostics-connected",
            [
                sys.executable,
                str(repo_root / "tools" / "scripts" / "device_app.py"),
                "diagnostics-connected",
                "--output-dir",
                str(device_output_dir),
                *flag("--include-crash-logs", args.include_crash_logs),
                *flag("--include-sysdiagnose", args.include_sysdiagnose),
            ],
        )
        steps.append(step)
        artifact_paths.extend(discover_device_artifacts(device_output_dir))

    if not args.skip_intake and (args.handles or args.device):
        intake_output_dir = output_dir / "reliability-intake"
        step = run_step(
            "reliability-intake",
            [
                sys.executable,
                str(repo_root / "tools" / "scripts" / "reliability_intake.py"),
                "--base-url",
                args.base_url,
                "--surface",
                "debug",
                "--output-dir",
                str(intake_output_dir),
                "--backend-timeout",
                str(args.backend_timeout),
                "--telemetry-hours",
                str(args.telemetry_hours),
                "--telemetry-limit",
                str(args.telemetry_limit),
                *flag("--include-heartbeats", args.include_heartbeats),
                *flag("--no-telemetry", args.no_telemetry),
                *flag("--compact", args.compact),
                *flag("--insecure", args.insecure),
                *option("--incident-id", args.incident_id),
                *device_options(args.device),
                *args.handles,
            ],
        )
        steps.append(step)
        artifact_paths.extend(discover_intake_artifacts(intake_output_dir))

    artifact_paths = dedupe(existing_paths(artifact_paths))
    physical_devices = dedupe([device.strip() for device in args.physical_device if device.strip()])
    if not physical_devices:
        physical_devices = devices_from_device_manifests(artifact_paths)

    manifest_step = run_step(
        "physical-device-boundary-manifest",
        [
            sys.executable,
            str(repo_root / "tools" / "scripts" / "physical_device_boundary_manifest.py"),
            "--output",
            manifest_output,
            *option("--since", evidence_since(args, run_started_at)),
            *physical_device_options(physical_devices),
            *artifact_paths,
        ],
    )
    steps.append(manifest_step)

    proof_step = run_step(
        "physical-device-boundary-proof",
        [
            sys.executable,
            str(repo_root / "tools" / "scripts" / "physical_device_boundary_proof.py"),
            "--manifest",
            manifest_output,
            "--output",
            proof_output,
            "--write-template",
        ],
    )
    steps.append(proof_step)
    proof_payload = read_json(Path(proof_output))

    proof_summary = summarize_proof(proof_payload)
    target_cell_proof = summarize_target_cell(proof_payload, args.target_cell)
    collection_ok = (
        target_cell_proof.get("ok") is True
        if args.target_cell.strip()
        else proof_step["ok"]
    )

    summary = {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "runStartedAt": run_started_at,
        "evidenceSince": evidence_since(args, run_started_at),
        "status": "pass" if collection_ok else "fail",
        "ok": collection_ok,
        "outputDir": str(output_dir),
        "manifest": manifest_output,
        "proof": proof_output,
        "artifacts": artifact_paths,
        "physicalDevices": physical_devices,
        "targetCell": args.target_cell,
        "targetCellPlan": collection_plan,
        "launchProfile": launch_profile,
        "wakeApnsSent": wake_apns_sent,
        "currentDevicePreflight": current_device_preflight,
        "currentLaunchabilityPreflight": current_launchability_preflight,
        "apnsCredentialPreflight": apns_credential_preflight,
        "operatorBlockers": operator_blockers,
        "launchFailures": launch_failures,
        "proofSummary": proof_summary,
        "targetCellProof": target_cell_proof,
        "nextCommands": next_commands(args, output_dir),
        "steps": steps,
    }
    summary_path = Path(args.summary_output) if args.summary_output else output_dir / "physical-device-boundary-collect.json"
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"physical-device boundary collection status: {summary['status']}")
    print(f"physical-device boundary collection artifact: {summary_path}")
    print(f"physical-device boundary manifest: {manifest_output}")
    print(f"physical-device boundary proof: {proof_output}")
    return 0 if summary["ok"] else 1


def resolve_output_dir(args: argparse.Namespace) -> Path:
    if args.output_dir.strip():
        return Path(args.output_dir)
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    return DEFAULT_OUTPUT_ROOT / timestamp


def evidence_since(args: argparse.Namespace, run_started_at: str) -> str:
    if args.skip_device_diagnostics:
        return ""
    return run_started_at


def resolve_proof_outputs(args: argparse.Namespace, output_dir: Path) -> tuple[str, str]:
    manifest_output = args.manifest_output
    proof_output = args.proof_output
    if args.target_cell.strip():
        if manifest_output == DEFAULT_MANIFEST_OUTPUT:
            manifest_output = str(output_dir / "physical-device-boundaries-manifest.json")
        if proof_output == DEFAULT_PROOF_OUTPUT:
            proof_output = str(output_dir / "physical-device-boundaries.json")
    return manifest_output, proof_output


def resolve_collection_plan(args: argparse.Namespace) -> dict[str, Any]:
    target_cell = args.target_cell.strip()
    launch_profile = args.launch_profile
    warnings: list[str] = []

    if target_cell:
        default_profile = TARGET_CELL_LAUNCH_PROFILES[target_cell]
        if launch_profile == "current" and default_profile != "current":
            launch_profile = default_profile
        elif launch_profile != default_profile and not args.allow_profile_mismatch:
            raise SystemExit(
                f"--target-cell {target_cell} requires --launch-profile {default_profile}; "
                "pass --allow-profile-mismatch only when the diagnostic artifacts already prove the context anchor"
            )

        if (
            target_cell == "lockscreen-apns-wake"
            and not args.send_wake_apns
            and not args.allow_manual_wake
            and not args.skip_device_diagnostics
        ):
            raise SystemExit(
                "--target-cell lockscreen-apns-wake requires --send-wake-apns with "
                "--wake-channel-id and --wake-handle, or --allow-manual-wake when wake delivery is external"
            )

        if args.skip_launch and default_profile != "current":
            warnings.append(
                "skip-launch is set; the collector will not apply the target cell launch profile"
            )

    return {
        "targetCell": target_cell,
        "launchProfile": launch_profile,
        "operatorSteps": TARGET_CELL_OPERATOR_STEPS.get(target_cell, []),
        "warnings": warnings,
    }


def should_collect_device_preflight(args: argparse.Namespace, launch_profile: str) -> bool:
    return bool(
        args.target_cell
        and (
            not args.skip_device_diagnostics
            or (not args.skip_launch and launch_profile != "current")
            or args.send_wake_apns
        )
    )


def should_collect_launchability_preflight(args: argparse.Namespace, launch_profile: str) -> bool:
    return False


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


def current_device_preflight_from_step(step: dict[str, Any]) -> dict[str, Any]:
    if not step.get("ok"):
        return {
            "status": "unknown",
            "ok": False,
            "error": (step.get("stderr") or step.get("stdout") or "").strip(),
            "devices": [],
            "blockers": ["current connected physical-device state is unknown"],
        }
    try:
        payload = json.loads(str(step.get("stdout") or ""))
    except json.JSONDecodeError as exc:
        return {
            "status": "unknown",
            "ok": False,
            "error": f"device list JSON invalid: {exc}",
            "devices": [],
            "blockers": ["current connected physical-device state is unknown"],
        }
    if not isinstance(payload, list):
        return {
            "status": "unknown",
            "ok": False,
            "error": "device list JSON was not a list",
            "devices": [],
            "blockers": ["current connected physical-device state is unknown"],
        }
    return current_device_preflight([device for device in payload if isinstance(device, dict)])


def launchability_preflight_from_file(path: Path, step: dict[str, Any]) -> dict[str, Any]:
    if not path.exists():
        return {
            "status": "unknown",
            "ok": False,
            "artifact": str(path),
            "error": (step.get("stderr") or step.get("stdout") or "").strip(),
            "devices": [],
            "blockers": ["device launchability state is unknown"],
        }
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {
            "status": "unknown",
            "ok": False,
            "artifact": str(path),
            "error": f"launchability JSON invalid: {exc}",
            "devices": [],
            "blockers": ["device launchability state is unknown"],
        }
    if not isinstance(payload, list):
        return {
            "status": "unknown",
            "ok": False,
            "artifact": str(path),
            "error": "launchability JSON was not a list",
            "devices": [],
            "blockers": ["device launchability state is unknown"],
        }
    devices = [compact_launchability_item(item) for item in payload if isinstance(item, dict)]
    failed = [device for device in devices if device.get("ok") is not True]
    reasons = sorted({str(device.get("reason") or "unknown") for device in failed})
    return {
        "status": "pass" if not failed else "fail",
        "ok": not failed,
        "artifact": str(path),
        "launchablePhysicalDeviceCount": len(devices) - len(failed),
        "failedPhysicalDeviceCount": len(failed),
        "failureReasons": reasons,
        "devices": devices,
    }


def compact_launchability_item(item: dict[str, Any]) -> dict[str, Any]:
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


def launchability_preflight_blockers(preflight: dict[str, Any]) -> list[str]:
    reasons = preflight.get("failureReasons") if isinstance(preflight.get("failureReasons"), list) else []
    blockers: list[str] = []
    if "locked" in reasons:
        blockers.append("device locked; unlock all connected physical devices before target-cell launch")
    if "device-disconnected" in reasons:
        blockers.append("device disconnected during command; reconnect the physical device before target-cell launch")
    if "device-unavailable" in reasons:
        blockers.append("device unavailable to CoreDevice; reconnect or unlock the physical device before target-cell launch")
    return blockers


def launchability_failure_details(preflight: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    devices = preflight.get("devices") if isinstance(preflight.get("devices"), list) else []
    for device in devices:
        if not isinstance(device, dict) or device.get("ok") is True:
            continue
        reason = str(device.get("reason") or "")
        if reason not in {"locked", "device-disconnected", "device-unavailable"}:
            continue
        failures.append(
            {
                "device": str(device.get("name") or ""),
                "udid": str(device.get("udid") or ""),
                "reason": reason,
                "message": str(device.get("message") or ""),
            }
        )
    return dedupe_failure_details(failures)


def apns_credential_preflight_from_step(step: dict[str, Any]) -> dict[str, Any]:
    try:
        payload = json.loads(str(step.get("stdout") or "{}"))
    except json.JSONDecodeError as exc:
        return {
            "status": "unknown",
            "ok": False,
            "error": f"APNs credential JSON invalid: {exc}",
            "missing": [],
        }
    if not isinstance(payload, dict):
        return {
            "status": "unknown",
            "ok": False,
            "error": "APNs credential JSON was not an object",
            "missing": [],
        }
    missing = payload.get("missing") if isinstance(payload.get("missing"), list) else []
    return {
        "status": "pass" if step.get("ok") and payload.get("ok") is True else "fail",
        "ok": step.get("ok") is True and payload.get("ok") is True,
        "missing": [str(item) for item in missing],
        "hasTeamId": payload.get("hasTeamId") is True,
        "hasKeyId": payload.get("hasKeyId") is True,
        "hasInlinePrivateKey": payload.get("hasInlinePrivateKey") is True,
        "hasPrivateKeyPath": payload.get("hasPrivateKeyPath") is True,
        "privateKeyPathExists": payload.get("privateKeyPathExists"),
    }


def apns_credential_blockers(preflight: dict[str, Any]) -> list[str]:
    missing = preflight.get("missing") if isinstance(preflight.get("missing"), list) else []
    if missing:
        return ["APNs credentials missing for wake send: " + ", ".join(str(item) for item in missing)]
    return ["APNs credential preflight failed"]


def current_device_preflight(devices: list[dict[str, Any]]) -> dict[str, Any]:
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
    }


def command_readiness_status(connected_count: int) -> str:
    if connected_count >= 2:
        return "ready"
    if connected_count == 1:
        return "partial"
    return "none"


def wait_step(name: str, seconds: float) -> dict[str, Any]:
    started = time.monotonic()
    time.sleep(seconds)
    elapsed = time.monotonic() - started
    return {
        "name": name,
        "ok": True,
        "exitCode": 0,
        "seconds": seconds,
        "elapsedSeconds": round(elapsed, 3),
    }


def skipped_step(name: str, reason: str) -> dict[str, Any]:
    return {
        "name": name,
        "ok": False,
        "exitCode": None,
        "skipped": True,
        "reason": reason,
    }


def classify_launch_failure(step: dict[str, Any]) -> list[str]:
    text = f"{step.get('stdout') or ''}\n{step.get('stderr') or ''}"
    blockers: list[str] = []
    if "device was not, or could not be, unlocked" in text or "BSErrorCodeDescription = Locked" in text:
        blockers.append("device locked; unlock all connected physical devices before target-cell launch")
    if "device disconnected immediately after connecting" in text:
        blockers.append("device disconnected during command; reconnect the physical device before target-cell launch")
    if "application failed to launch" in text or "failed to launch" in text:
        blockers.append("app launch failed; target-cell transport profile was not applied")
    return dedupe(blockers)


def classify_launch_failure_details(step: dict[str, Any]) -> list[dict[str, str]]:
    text = f"{step.get('stdout') or ''}\n{step.get('stderr') or ''}"
    current: dict[str, str] | None = None
    pending: dict[str, str] | None = None
    failures: list[dict[str, str]] = []
    for line in text.splitlines():
        if line.startswith("== ") and line.endswith(" =="):
            if pending is not None:
                failures.append(pending)
                pending = None
            label = line.removeprefix("== ").removesuffix(" ==")
            name, udid = parse_device_heading(label)
            current = {"device": name, "udid": udid}
            continue
        if current is None:
            continue
        if (
            "device was not, or could not be, unlocked" in line
            or "BSErrorCodeDescription = Locked" in line
        ):
            failures.append(
                {
                    **current,
                    "reason": "locked",
                    "message": "Unable to launch because the device was not, or could not be, unlocked.",
                }
            )
            current = None
            pending = None
        elif "application failed to launch" in line or "failed to launch" in line:
            pending = {
                **current,
                "reason": "launch-failed",
                "message": line.strip(),
            }
        elif "device disconnected immediately after connecting" in line:
            failures.append(
                {
                    **current,
                    "reason": "device-disconnected",
                    "message": "The device disconnected immediately after connecting.",
                }
            )
            current = None
            pending = None
        elif line.startswith("run-connected failed for device(s): "):
            failures.extend(parse_run_connected_failure_summary(line))
    if pending is not None:
        failures.append(pending)
    return dedupe_failure_details(failures)


def parse_run_connected_failure_summary(line: str) -> list[dict[str, str]]:
    _, _, raw_failures = line.partition(": ")
    failures: list[dict[str, str]] = []
    for raw_failure in raw_failures.split(";"):
        value = raw_failure.strip()
        if not value:
            continue
        label, _, code = value.rpartition(" exit=")
        name, udid = parse_device_heading(label)
        failures.append(
            {
                "device": name,
                "udid": udid,
                "reason": "device-command-failed",
                "message": f"run-connected exited {code or 'nonzero'} for this device",
            }
        )
    return failures


def parse_device_heading(label: str) -> tuple[str, str]:
    if label.endswith(")") and " (" in label:
        name, _, udid = label.rpartition(" (")
        return name, udid.removesuffix(")")
    return label, ""


def dedupe_failure_details(failures: list[dict[str, str]]) -> list[dict[str, str]]:
    by_device: dict[tuple[str, str], dict[str, str]] = {}
    order: list[tuple[str, str]] = []
    priority = {
        "locked": 3,
        "launch-failed": 2,
        "device-disconnected": 2,
        "device-unavailable": 2,
        "device-command-failed": 1,
    }
    for failure in failures:
        key = (
            failure.get("device", ""),
            failure.get("udid", ""),
        )
        if key not in by_device:
            order.append(key)
            by_device[key] = failure
            continue
        existing = by_device[key]
        if priority.get(failure.get("reason", ""), 0) > priority.get(existing.get("reason", ""), 0):
            by_device[key] = failure
    result: list[dict[str, str]] = []
    for key in order:
        result.append(by_device[key])
    return result


def launch_profile_environment(profile: str) -> list[str]:
    variables = {
        "direct-quic": {
            "TURBO_DEBUG_FORCE_RELAY_ONLY": "0",
            "TURBO_DEBUG_DISABLE_DIRECT_QUIC_AUTO_UPGRADE": "0",
            "TURBO_DEBUG_MEDIA_RELAY_ENABLED": "0",
            "TURBO_DEBUG_FORCE_MEDIA_RELAY": "0",
            "TURBO_DEBUG_DIRECT_QUIC_TRANSMIT_STARTUP_POLICY": "apple-gated",
        },
        "fallback-relay": {
            "TURBO_DEBUG_FORCE_RELAY_ONLY": "0",
            "TURBO_DEBUG_DISABLE_DIRECT_QUIC_AUTO_UPGRADE": "1",
            "TURBO_DEBUG_MEDIA_RELAY_ENABLED": "1",
            "TURBO_DEBUG_FORCE_MEDIA_RELAY": "1",
            "TURBO_DEBUG_DIRECT_QUIC_TRANSMIT_STARTUP_POLICY": "apple-gated",
        },
    }.get(profile, {})
    result: list[str] = []
    for key, value in variables.items():
        result.extend(["--env", f"{key}={value}"])
    return result


def discover_device_artifacts(root: Path) -> list[str]:
    patterns = [
        "manifest.json",
        "beepbeep-diagnostics-tail.log",
        "beepbeep-diagnostics.log",
    ]
    return discover_artifacts(root, patterns)


def discover_intake_artifacts(root: Path) -> list[str]:
    patterns = [
        "merged-diagnostics.json",
        "merged-diagnostics.txt",
        "audio-incident-corpus.json",
    ]
    return discover_artifacts(root, patterns)


def discover_artifacts(root: Path, names: list[str]) -> list[str]:
    if not root.exists():
        return []
    artifacts: list[str] = []
    for name in names:
        artifacts.extend(str(path) for path in sorted(root.rglob(name)) if path.is_file())
    return artifacts


def devices_from_device_manifests(artifact_paths: list[str]) -> list[str]:
    devices: list[str] = []
    for path in artifact_paths:
        if Path(path).name != "manifest.json":
            continue
        payload = read_json(Path(path))
        device = payload.get("device") if isinstance(payload, dict) else None
        if not isinstance(device, dict):
            continue
        for key in ("udid", "name", "devicectlIdentifier"):
            value = device.get(key)
            if isinstance(value, str) and value.strip():
                devices.append(value.strip())
                break
    return dedupe(devices)


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def summarize_proof(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        return {
            "status": "missing",
            "failedCells": [],
            "passedCells": [],
        }
    cells = payload.get("cells")
    cell_items = cells if isinstance(cells, list) else []
    failed = [
        {
            "name": str(cell.get("name") or ""),
            "reason": str(cell.get("reason") or ""),
        }
        for cell in cell_items
        if isinstance(cell, dict) and cell.get("status") != "pass"
    ]
    passed = [
        str(cell.get("name") or "")
        for cell in cell_items
        if isinstance(cell, dict) and cell.get("status") == "pass"
    ]
    return {
        "status": str(payload.get("status") or "unknown"),
        "failedCells": failed,
        "passedCells": passed,
        "recommendedNextRuns": recommended_next_runs(failed),
    }


def summarize_target_cell(payload: Any, target_cell: str) -> dict[str, Any]:
    if not target_cell.strip() or not isinstance(payload, dict):
        return {}
    cells = payload.get("cells")
    if not isinstance(cells, list):
        return {
            "name": target_cell,
            "status": "missing",
            "ok": False,
            "reason": "proof artifact did not contain cells",
            "missingEvidence": [],
            "missingContext": [],
        }
    for cell in cells:
        if not isinstance(cell, dict) or cell.get("name") != target_cell:
            continue
        return {
            "name": target_cell,
            "status": str(cell.get("status") or "unknown"),
            "ok": bool(cell.get("ok")),
            "reason": str(cell.get("reason") or ""),
            "missingEvidence": missing_checks(cell.get("evidence")),
            "missingContext": missing_checks(cell.get("context")),
        }
    return {
        "name": target_cell,
        "status": "missing",
        "ok": False,
        "reason": "target cell was not present in proof artifact",
        "missingEvidence": [],
        "missingContext": [],
    }


def missing_checks(entries: Any) -> list[str]:
    if not isinstance(entries, list):
        return []
    checks: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("ok") is True:
            continue
        check = entry.get("check")
        if isinstance(check, str) and check:
            checks.append(check)
    return checks


def next_commands(args: argparse.Namespace, output_dir: Path) -> list[dict[str, str]]:
    commands: list[dict[str, str]] = []
    if args.target_cell.strip():
        commands.append(
            {
                "name": "rerun-target-cell",
                "description": "Rerun this physical boundary cell into the same run directory.",
                "command": just_collect_command(args, output_dir),
            }
        )
    commands.append(
        {
            "name": "finalize-canonical-physical-proof",
            "description": "Merge passing cells from this run into the canonical physical proof artifact.",
            "command": shell_command(
                [
                    "just",
                    "physical-device-boundary-finalize",
                    str(output_dir),
                ]
            ),
        }
    )
    return commands


def just_collect_command(args: argparse.Namespace, output_dir: Path) -> str:
    target_args = ["--target-cell", args.target_cell.strip()]
    if args.allow_profile_mismatch:
        target_args.append("--allow-profile-mismatch")
    if args.allow_manual_wake:
        target_args.append("--allow-manual-wake")
    launch_profile = args.launch_profile
    target_cell = args.target_cell.strip()
    if target_cell and not args.allow_profile_mismatch:
        launch_profile = TARGET_CELL_LAUNCH_PROFILES[target_cell]

    recipe_args = [
        shell_fragment(args.handles),
        repeated_option_fragment("--device", args.device),
        repeated_option_fragment("--physical-device", args.physical_device),
        repeated_option_fragment("--artifact", args.artifact),
        str(output_dir),
        "--insecure" if args.insecure else "",
        launch_profile,
        wake_args_fragment(args),
        str(args.pre_collect_wait_seconds),
        shell_fragment(target_args),
    ]
    return shell_command(["just", "physical-device-boundary-collect", *recipe_args])


def wake_args_fragment(args: argparse.Namespace) -> str:
    values: list[str] = []
    if args.send_wake_apns:
        values.append("--send-wake-apns")
    if args.wake_channel_id.strip():
        values.extend(["--wake-channel-id", args.wake_channel_id])
    if args.wake_handle.strip():
        values.extend(["--wake-handle", args.wake_handle])
    if args.wake_bundle_id.strip() and args.wake_bundle_id != "com.rounded.Turbo":
        values.extend(["--wake-bundle-id", args.wake_bundle_id])
    if args.post_wake_wait_seconds != 8.0:
        values.extend(["--post-wake-wait-seconds", str(args.post_wake_wait_seconds)])
    return shell_fragment(values)


def repeated_option_fragment(name: str, values: list[str]) -> str:
    parts: list[str] = []
    for value in values:
        if value.strip():
            parts.extend([name, value])
    return shell_fragment(parts)


def shell_fragment(values: list[str]) -> str:
    return shlex.join([value for value in values if value])


def shell_command(values: list[str]) -> str:
    return shlex.join(values)


def recommended_next_runs(failed_cells: list[dict[str, str]]) -> list[dict[str, str]]:
    recommendations: list[dict[str, str]] = []
    failed_names = {cell["name"] for cell in failed_cells}
    if "direct-quic-media" in failed_names:
        recommendations.append(
            {
                "cell": "direct-quic-media",
                "launchProfile": "direct-quic",
                "reason": "Direct QUIC media proof requires a run without media relay forced.",
            }
        )
    if "fallback-relay-audio" in failed_names:
        recommendations.append(
            {
                "cell": "fallback-relay-audio",
                "launchProfile": "fallback-relay",
                "reason": "Fallback relay proof requires a run with Direct QUIC upgrade disabled and media relay forced.",
            }
        )
    if "lockscreen-apns-wake" in failed_names:
        recommendations.append(
            {
                "cell": "lockscreen-apns-wake",
                "launchProfile": "current",
                "reason": "Wake proof requires a physical locked/background receiver, --send-wake-apns, and a real PushToTalk APNs wake.",
            }
        )
    return recommendations


def existing_paths(paths: list[str]) -> list[str]:
    return [str(Path(path)) for path in paths if path and Path(path).exists()]


def physical_device_options(devices: list[str]) -> list[str]:
    options: list[str] = []
    for device in devices:
        options.extend(["--device", device])
    return options


def device_options(devices: list[str]) -> list[str]:
    options: list[str] = []
    for device in devices:
        options.extend(["--device", device])
    return options


def option(name: str, value: str) -> list[str]:
    return [name, value] if value.strip() else []


def flag(name: str, enabled: bool) -> list[str]:
    return [name] if enabled else []


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
