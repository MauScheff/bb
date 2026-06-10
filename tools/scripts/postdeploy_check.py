#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_OUTPUT_DIR = Path("/tmp/turbo-postdeploy-check")


@dataclass(frozen=True)
class StepResult:
    name: str
    ok: bool
    exit_code: int
    duration_ms: int
    command: list[str]
    output_path: str
    artifact_path: str | None

    def to_json(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "ok": self.ok,
            "exitCode": self.exit_code,
            "durationMs": self.duration_ms,
            "command": self.command,
            "outputPath": self.output_path,
            "artifactPath": self.artifact_path,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the hosted Turbo postdeploy canary and SLO dashboard."
    )
    parser.add_argument("--base-url", default="https://api.beepbeep.to")
    parser.add_argument("--caller", default="@quinn")
    parser.add_argument("--callee", default="@sasha")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR))
    parser.add_argument("--name", default="turbo-postdeploy-check")
    parser.add_argument("--insecure", action="store_true")
    parser.add_argument("--command-timeout", type=int, default=240)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.iterations < 1:
        raise SystemExit("--iterations must be >= 1")

    started_at = utc_now()
    run_dir = Path(args.output_dir) / f"{timestamp_for_path()}-{sanitize_name(args.name)}"
    simulator_artifact = run_dir / "simulator-self-hosted-suite.json"
    run_dir.mkdir(parents=True, exist_ok=True)

    steps: list[StepResult] = []

    simulator_command = [
        sys.executable,
        "backend/scripts/simulator_self_hosted_suite_proof.py",
        "--base-url",
        args.base_url.rstrip("/") + "/s/turbo",
        "--scenario",
        "beep_accept_ready",
        "--output",
        str(simulator_artifact),
    ]
    if args.insecure:
        simulator_command.append("--insecure")

    simulator_result = run_step(
        name="hosted-simulator-postdeploy",
        command=simulator_command,
        output_path=run_dir / "hosted-simulator-postdeploy.output.txt",
        artifact_path=simulator_artifact,
    )
    steps.append(simulator_result)

    ended_at = utc_now()
    ok = all(step.ok for step in steps)
    summary = {
        "schemaVersion": 1,
        "name": args.name,
        "ok": ok,
        "status": "pass" if ok else "fail",
        "baseUrl": args.base_url,
        "caller": args.caller,
        "callee": args.callee,
        "iterations": args.iterations,
        "startedAt": started_at,
        "endedAt": ended_at,
        "runDir": str(run_dir),
        "hostedSimulatorSuite": str(simulator_artifact) if simulator_artifact.exists() else None,
        "steps": [step.to_json() for step in steps],
        "reproduceCommand": str(run_dir / "reproduce.sh"),
    }
    write_json(run_dir / "postdeploy-check.json", summary)
    write_reproduce_script(run_dir, args)

    print(f"postdeploy check status: {summary['status']}")
    print(f"postdeploy check artifacts: {run_dir}")
    if simulator_artifact.exists():
        print(f"hosted simulator suite: {simulator_artifact}")
    return 0 if summary["ok"] else 1


def run_step(
    *,
    name: str,
    command: list[str],
    output_path: Path,
    artifact_path: Path,
) -> StepResult:
    started = time.perf_counter()
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    duration_ms = int((time.perf_counter() - started) * 1000)
    output_path.write_text(render_command_output(command, completed), encoding="utf-8")
    return StepResult(
        name=name,
        ok=completed.returncode == 0,
        exit_code=completed.returncode,
        duration_ms=duration_ms,
        command=command,
        output_path=str(output_path),
        artifact_path=str(artifact_path) if artifact_path.exists() else None,
    )


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


def write_reproduce_script(run_dir: Path, args: argparse.Namespace) -> None:
    command = [
        sys.executable,
        "tools/scripts/postdeploy_check.py",
        "--base-url",
        args.base_url,
        "--caller",
        args.caller,
        "--callee",
        args.callee,
        "--iterations",
        str(args.iterations),
        "--output-dir",
        str(run_dir.parent),
        "--name",
        args.name,
        "--command-timeout",
        str(args.command_timeout),
    ]
    if args.insecure:
        command.append("--insecure")
    script = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f"cd {shell_quote(str(Path.cwd()))}\n"
        + " ".join(shell_quote(part) for part in command)
        + "\n"
    )
    path = run_dir / "reproduce.sh"
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def timestamp_for_path() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def sanitize_name(value: str) -> str:
    sanitized = "".join(char if char.isalnum() or char in ("-", "_") else "-" for char in value)
    return sanitized.strip("-") or "postdeploy-check"


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    raise SystemExit(main())
