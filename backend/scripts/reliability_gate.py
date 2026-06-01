#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_BASE_URL = os.environ.get(
    "BEEP_BEEP_BACKEND_BASE_URL", "https://api.beepbeep.to"
)
DEFAULT_OUTPUT = "/tmp/beepbeep-backend-reliability-gate.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the canonical Beep Beep backend reliability gate."
    )
    parser.add_argument("mode", nargs="?", choices=["local", "production", "cutover"], default="local")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--seed", default="123")
    parser.add_argument("--count", default="3")
    parser.add_argument("--runtime-count", default="16")
    parser.add_argument("--shadow-count", default="8")
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument("--run-dir", default="")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    started_monotonic = time.monotonic()
    started_at = utc_now()
    run_dir = Path(args.run_dir) if args.run_dir else Path("/tmp/beepbeep-backend-gate") / path_timestamp()
    run_dir.mkdir(parents=True, exist_ok=True)

    steps = planned_steps(args)
    if args.dry_run:
        summary = build_summary(args, started_at, utc_now(), run_dir, [], "pass")
        summary["plannedCommands"] = [step["command"] for step in steps]
        write_outputs(summary, Path(args.output), run_dir, args)
        print(f"beepbeep backend reliability gate dry-run: {args.mode}")
        print(f"beepbeep backend reliability gate artifact: {args.output}")
        return 0

    results: list[dict[str, Any]] = []
    status = "pass"
    for step in steps:
        result = run_step(step, run_dir)
        results.append(result)
        if not result["ok"]:
            status = "fail"
            break

    if status == "pass":
        validation = (
            validate_cutover_readiness(started_monotonic)
            if args.mode == "cutover"
            else validate_artifacts(args, started_monotonic)
        )
        results.extend(validation)
        if any(not result["ok"] for result in validation):
            status = "fail"

    summary = build_summary(args, started_at, utc_now(), run_dir, results, status)
    write_outputs(summary, Path(args.output), run_dir, args)
    print(f"beepbeep backend reliability gate status: {status}")
    print(f"beepbeep backend reliability gate artifact: {args.output}")
    print(f"beepbeep backend reliability gate run dir: {run_dir}")
    return 0 if status == "pass" else 1


def planned_steps(args: argparse.Namespace) -> list[dict[str, Any]]:
    if args.mode == "cutover":
        return [
            {
                "name": "self-hosted-cutover-readiness",
                "command": ["just", "self-hosted-cutover-readiness"],
            }
        ]

    steps = [
        {"name": "kernel-fuzz", "command": ["just", "kernel-fuzz"]},
        {
            "name": "kernel-corpus-json",
            "command": ["just", "kernel-corpus-json", "/tmp/turbo-kernel-corpus.json"],
        },
        {
            "name": "rust-runtime-fuzz",
            "command": [
                "just",
                "rust-runtime-fuzz",
                args.seed,
                args.runtime_count,
                "/tmp/turbo-rust-runtime-fuzz/report.json",
            ],
        },
        {"name": "self-hosted-http-probe", "command": ["just", "self-hosted-http-probe"]},
        {"name": "self-hosted-websocket-probe", "command": ["just", "self-hosted-websocket-probe"]},
        {
            "name": "self-hosted-scenario-fuzz-local",
            "command": [
                "just",
                "self-hosted-scenario-fuzz-local",
                args.seed,
                args.count,
                "/tmp/turbo-self-hosted-fuzz/report.json",
            ],
        },
        {
            "name": "shadow-backend-fuzz",
            "command": [
                "just",
                "shadow-backend-fuzz",
                args.seed,
                args.shadow_count,
                "/tmp/turbo-shadow-backend-fuzz/report.json",
            ],
        },
        {"name": "rust-runtime-integration", "command": ["just", "rust-runtime-integration"]},
    ]

    if args.mode == "production":
        simulator_base = args.base_url.rstrip("/") + "/s/turbo"
        synthetic_suffix = uuid.uuid4().hex[:8]
        synthetic_caller = f"@gatecaller{synthetic_suffix}"
        synthetic_callee = f"@gatecallee{synthetic_suffix}"
        steps.extend(
            [
                {
                    "name": "simulator-scenario-suite-self-hosted",
                    "command": [
                        "just",
                        "simulator-scenario-suite-self-hosted",
                        simulator_base,
                        "/tmp/turbo-simulator-self-hosted-suite.json",
                        "",
                        "--insecure",
                    ],
                },
                {
                    "name": "postdeploy-check",
                    "command": [
                        "just",
                        "postdeploy-check",
                        args.base_url,
                        synthetic_caller,
                        synthetic_callee,
                        "1",
                        "/tmp/beepbeep-postdeploy-check",
                        "--insecure",
                    ],
                },
            ]
        )
    return steps


def run_step(step: dict[str, Any], run_dir: Path) -> dict[str, Any]:
    started = time.perf_counter()
    completed = subprocess.run(step["command"], capture_output=True, text=True, check=False)
    duration_ms = int((time.perf_counter() - started) * 1000)
    output_path = run_dir / f"{step['name']}.txt"
    output_path.write_text(render_command_output(step["command"], completed), encoding="utf-8")
    return {
        "name": step["name"],
        "kind": "command",
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "durationMs": duration_ms,
        "command": step["command"],
        "outputPath": str(output_path),
    }


def validate_artifacts(args: argparse.Namespace, started_monotonic: float) -> list[dict[str, Any]]:
    checks = [
        artifact_check("kernel-corpus", "/tmp/turbo-kernel-corpus.json", lambda p: require_cases(p, 10)),
        artifact_check("rust-runtime-fuzz", "/tmp/turbo-rust-runtime-fuzz/report.json", lambda p: require_gate(p, "rust-runtime-fuzz")),
        artifact_check("self-hosted-http-probe", "/tmp/turbo-self-hosted-http-probe.json", require_ok),
        artifact_check("self-hosted-websocket-probe", "/tmp/turbo-self-hosted-websocket-probe.json", require_ok),
        artifact_check("self-hosted-scenario-fuzz-local", "/tmp/turbo-self-hosted-fuzz/report.json", lambda p: require_gate(p, "self-hosted-scenario-fuzz-local")),
        artifact_check("shadow-backend-fuzz", "/tmp/turbo-shadow-backend-fuzz/report.json", lambda p: require_gate(p, "shadow-backend-fuzz")),
        artifact_check("rust-runtime-integration", "/tmp/turbo-rust-runtime-integration.json", require_ok),
    ]
    if args.mode == "production":
        checks.append(
            artifact_check("simulator-self-hosted-suite", "/tmp/turbo-simulator-self-hosted-suite.json", require_ok)
        )

    results = []
    for check in checks:
        result = check
        path = Path(result["artifact"])
        if result["ok"] and path.exists():
            age_ok = path.stat().st_mtime >= process_start_epoch(started_monotonic) - 1
            result["fresh"] = age_ok
            result["ok"] = result["ok"] and age_ok
            if not age_ok:
                result["reason"] = "artifact was not regenerated by this gate run"
        results.append(result)
    return results


def validate_cutover_readiness(started_monotonic: float) -> list[dict[str, Any]]:
    result = artifact_check(
        "self-hosted-cutover-readiness",
        "/tmp/turbo-self-hosted-cutover-readiness.json",
        require_ready,
    )
    path = Path(result["artifact"])
    if result["ok"] and path.exists():
        age_ok = path.stat().st_mtime >= process_start_epoch(started_monotonic) - 1
        result["fresh"] = age_ok
        result["ok"] = result["ok"] and age_ok
        if not age_ok:
            result["reason"] = "artifact was not regenerated by this gate run"
    return [result]


def artifact_check(name: str, path: str, validator) -> dict[str, Any]:
    artifact = Path(path)
    if not artifact.exists():
        return {
            "name": name,
            "kind": "artifact",
            "ok": False,
            "artifact": path,
            "reason": "missing artifact",
        }
    payload = read_json(artifact)
    if payload is None:
        return {
            "name": name,
            "kind": "artifact",
            "ok": False,
            "artifact": path,
            "reason": "invalid JSON artifact",
        }
    ok, reason = validator(payload)
    return {
        "name": name,
        "kind": "artifact",
        "ok": ok,
        "artifact": path,
        "reason": reason,
    }


def require_ok(payload: dict[str, Any]) -> tuple[bool, str]:
    ok = payload.get("ok") is True or payload.get("status") in {"pass", "ok", "ready"}
    return ok, "ok" if ok else "artifact did not report ok/pass"


def require_ready(payload: dict[str, Any]) -> tuple[bool, str]:
    ok = payload.get("ready") is True and payload.get("status") == "ready"
    return ok, "ok" if ok else "readiness artifact did not report ready"


def require_gate(payload: dict[str, Any], gate: str) -> tuple[bool, str]:
    if payload.get("gate") != gate:
        return False, f"gate mismatch: {payload.get('gate')!r}"
    ok = payload.get("ok") is True or payload.get("status") in {"pass", "ok"}
    if not ok:
        return False, "gate artifact did not report ok/pass"
    checks = payload.get("checks")
    if not isinstance(checks, list) or not checks:
        return False, "gate artifact has no checks"
    return True, "ok"


def require_cases(payload: dict[str, Any], minimum: int) -> tuple[bool, str]:
    cases = payload.get("cases")
    if not isinstance(cases, list) or len(cases) < minimum:
        return False, f"expected at least {minimum} cases"
    return True, "ok"


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        return payload if isinstance(payload, dict) else None
    except Exception:
        return None


def process_start_epoch(started_monotonic: float) -> float:
    return time.time() - (time.monotonic() - started_monotonic)


def build_summary(
    args: argparse.Namespace,
    started_at: str,
    ended_at: str,
    run_dir: Path,
    results: list[dict[str, Any]],
    status: str,
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "mode": args.mode,
        "baseUrl": args.base_url,
        "seed": args.seed,
        "count": args.count,
        "startedAt": started_at,
        "endedAt": ended_at,
        "status": status,
        "ok": status == "pass",
        "runDir": str(run_dir),
        "steps": results,
        "blockingFailures": [result for result in results if result.get("ok") is not True],
        "reproduceCommand": str(run_dir / "reproduce.sh"),
    }


def write_outputs(summary: dict[str, Any], output: Path, run_dir: Path, args: argparse.Namespace) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_reproduce_script(run_dir, args)


def write_reproduce_script(run_dir: Path, args: argparse.Namespace) -> None:
    command = [
        sys.executable,
        "backend/scripts/reliability_gate.py",
        args.mode,
        "--base-url",
        args.base_url,
        "--seed",
        args.seed,
        "--count",
        args.count,
        "--runtime-count",
        args.runtime_count,
        "--shadow-count",
        args.shadow_count,
        "--output",
        args.output,
    ]
    script = "#!/usr/bin/env bash\nset -euo pipefail\ncd " + shell_quote(str(Path.cwd())) + "\n"
    script += " ".join(shell_quote(part) for part in command) + "\n"
    path = run_dir / "reproduce.sh"
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def render_command_output(command: list[str], completed: subprocess.CompletedProcess[str]) -> str:
    return (
        "$ "
        + " ".join(shell_quote(part) for part in command)
        + "\n\n--- stdout ---\n"
        + completed.stdout
        + "\n--- stderr ---\n"
        + completed.stderr
        + f"\n--- exitCode: {completed.returncode} ---\n"
    )


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def path_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    raise SystemExit(main())
