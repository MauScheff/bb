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


DEFAULT_ARTIFACT_DIR = Path("/tmp/turbo-synthetic-conversation-probe")
DEFAULT_REQUIRED_CHECKS = (
    "websocket-register",
    "channel-readiness:caller:receiver-ready",
    "channel-readiness:callee:receiver-ready",
    "channel-begin-transmit",
    "wake-events:recent:after-begin-transmit",
    "channel-end-transmit",
)


@dataclass(frozen=True)
class IterationResult:
    index: int
    ok: bool
    exit_code: int
    duration_ms: int
    report_path: str
    output_path: str | None
    error: str | None
    missing_required_checks: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run synthetic two-device Turbo conversation probes and write replayable artifacts."
    )
    parser.add_argument("--base-url", default="https://api.beepbeep.to")
    parser.add_argument("--caller", default="@quinn")
    parser.add_argument("--callee", default="@sasha")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--artifact-dir", default=str(DEFAULT_ARTIFACT_DIR))
    parser.add_argument("--insecure", action="store_true")
    parser.add_argument("--command-timeout", type=int, default=240)
    parser.add_argument("--route-probe-python", default="")
    parser.add_argument("--fixture-report", action="append", default=[])
    parser.add_argument("--required-check", action="append", default=[])
    parser.add_argument("--label", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.iterations < 1:
        raise SystemExit("--iterations must be >= 1")

    artifact_dir = Path(args.artifact_dir)
    artifact_dir.mkdir(parents=True, exist_ok=True)
    started_at = utc_now()
    required_checks = tuple(args.required_check or DEFAULT_REQUIRED_CHECKS)
    fixture_reports = [Path(path) for path in args.fixture_report]
    route_probe_python = args.route_probe_python or default_route_probe_python()
    iterations: list[IterationResult] = []
    reports: list[dict[str, Any]] = []

    write_reproduce_script(
        artifact_dir,
        args=args,
        required_checks=required_checks,
        route_probe_python=route_probe_python,
    )

    for index in range(1, args.iterations + 1):
        result, report = run_iteration(
            index=index,
            args=args,
            artifact_dir=artifact_dir,
            route_probe_python=route_probe_python,
            required_checks=required_checks,
            fixture_reports=fixture_reports,
        )
        iterations.append(result)
        reports.append(report)
        status = "passed" if result.ok else "failed"
        print(f"synthetic conversation probe {index}/{args.iterations} {status} ({result.duration_ms}ms)", flush=True)
        if not result.ok and not fixture_reports:
            break

    ended_at = utc_now()
    summary = build_summary(
        args=args,
        artifact_dir=artifact_dir,
        started_at=started_at,
        ended_at=ended_at,
        required_checks=required_checks,
        iterations=iterations,
        reports=reports,
    )
    write_json(artifact_dir / "synthetic-conversation-probe.json", summary)
    print(f"synthetic conversation probe artifacts: {artifact_dir}", flush=True)
    return 0 if summary["ok"] else 1


def default_route_probe_python() -> str:
    venv_python = Path(".venv/bin/python")
    if venv_python.exists():
        return str(venv_python)
    return sys.executable


def run_iteration(
    *,
    index: int,
    args: argparse.Namespace,
    artifact_dir: Path,
    route_probe_python: str,
    required_checks: tuple[str, ...],
    fixture_reports: list[Path],
) -> tuple[IterationResult, dict[str, Any]]:
    started = time.perf_counter()
    output_path: Path | None = None
    error: str | None = None
    exit_code = 0

    if fixture_reports:
        fixture_path = fixture_reports[(index - 1) % len(fixture_reports)]
        report = read_json(fixture_path)
        command = ["fixture-report", str(fixture_path)]
        stdout = json.dumps(report, indent=2, sort_keys=True) + "\n"
        stderr = ""
        exit_code = 0 if report.get("ok") is True else 1
    else:
        command = route_probe_command(args, route_probe_python)
        output_path = artifact_dir / f"iteration-{index:04d}-output.txt"
        completed = run_command(command, timeout=args.command_timeout)
        stdout = completed.stdout
        stderr = completed.stderr
        exit_code = completed.returncode
        output_path.write_text(
            render_command_output(command, completed),
            encoding="utf-8",
        )
        try:
            report = parse_json_report(stdout)
        except ValueError as exc:
            report = {
                "ok": False,
                "baseUrl": args.base_url,
                "checks": [],
                "error": f"route probe did not emit JSON: {exc}",
            }
            error = report["error"]

    missing_required_checks = missing_checks(report, required_checks)
    if missing_required_checks:
        error = "missing required check(s): " + ", ".join(missing_required_checks)

    duration_ms = int((time.perf_counter() - started) * 1000)
    ok = exit_code == 0 and report.get("ok") is True and not missing_required_checks
    if error is None and not ok:
        error = str(report.get("error") or f"route probe exited {exit_code}")

    iteration_payload = {
        "index": index,
        "ok": ok,
        "exitCode": exit_code,
        "durationMs": duration_ms,
        "command": command,
        "stdout": stdout if fixture_reports else None,
        "stderr": stderr if fixture_reports else None,
        "missingRequiredChecks": missing_required_checks,
        "error": error,
        "report": report,
    }
    report_path = artifact_dir / f"iteration-{index:04d}-report.json"
    write_json(report_path, iteration_payload)

    return (
        IterationResult(
            index=index,
            ok=ok,
            exit_code=exit_code,
            duration_ms=duration_ms,
            report_path=str(report_path),
            output_path=str(output_path) if output_path is not None else None,
            error=error,
            missing_required_checks=missing_required_checks,
        ),
        report,
    )


def route_probe_command(args: argparse.Namespace, route_probe_python: str) -> list[str]:
    command = [
        route_probe_python,
        "tools/scripts/route_probe.py",
        "--base-url",
        args.base_url,
        "--caller",
        args.caller,
        "--callee",
        args.callee,
        "--json",
    ]
    if args.insecure:
        command.append("--insecure")
    return command


def run_command(command: list[str], *, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
        return subprocess.CompletedProcess(command, 124, stdout, stderr + f"\nTimed out after {timeout}s\n")


def parse_json_report(stdout: str) -> dict[str, Any]:
    text = stdout.strip()
    if not text:
        raise ValueError("empty stdout")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end == -1 or end <= start:
            raise
        payload = json.loads(text[start:end + 1])
    if not isinstance(payload, dict):
        raise ValueError("JSON report was not an object")
    return payload


def missing_checks(report: dict[str, Any], required_checks: tuple[str, ...]) -> list[str]:
    checks = report.get("checks")
    if not isinstance(checks, list):
        return list(required_checks)
    names = {
        check.get("name")
        for check in checks
        if isinstance(check, dict)
    }
    return [name for name in required_checks if name not in names]


def build_summary(
    *,
    args: argparse.Namespace,
    artifact_dir: Path,
    started_at: str,
    ended_at: str,
    required_checks: tuple[str, ...],
    iterations: list[IterationResult],
    reports: list[dict[str, Any]],
) -> dict[str, Any]:
    passed = sum(1 for iteration in iterations if iteration.ok)
    failed = len(iterations) - passed
    return {
        "schemaVersion": 1,
        "ok": failed == 0 and len(iterations) == args.iterations,
        "label": args.label or None,
        "baseUrl": args.base_url,
        "caller": args.caller,
        "callee": args.callee,
        "iterationsRequested": args.iterations,
        "iterationsRun": len(iterations),
        "passed": passed,
        "failed": failed,
        "startedAt": started_at,
        "endedAt": ended_at,
        "artifactDir": str(artifact_dir),
        "requiredChecks": list(required_checks),
        "iterations": [
            {
                "index": iteration.index,
                "ok": iteration.ok,
                "exitCode": iteration.exit_code,
                "durationMs": iteration.duration_ms,
                "reportPath": iteration.report_path,
                "outputPath": iteration.output_path,
                "missingRequiredChecks": iteration.missing_required_checks,
                "error": iteration.error,
            }
            for iteration in iterations
        ],
        "checkStats": aggregate_check_stats(reports),
        "reproduceCommand": str(artifact_dir / "reproduce.sh"),
    }


def aggregate_check_stats(reports: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for report in reports:
        checks = report.get("checks")
        if not isinstance(checks, list):
            continue
        for check in checks:
            if not isinstance(check, dict):
                continue
            name = str(check.get("name") or "")
            if not name:
                continue
            grouped.setdefault(name, []).append(check)

    stats: list[dict[str, Any]] = []
    for name, checks in sorted(grouped.items()):
        durations = [
            int(check.get("durationMs") or 0)
            for check in checks
            if isinstance(check.get("durationMs"), int)
        ]
        failed_details = [
            str(check.get("detail") or "")
            for check in checks
            if check.get("ok") is not True
        ]
        stats.append(
            {
                "name": name,
                "count": len(checks),
                "passed": sum(1 for check in checks if check.get("ok") is True),
                "failed": sum(1 for check in checks if check.get("ok") is not True),
                "minDurationMs": min(durations) if durations else None,
                "p50DurationMs": percentile(durations, 50) if durations else None,
                "p95DurationMs": percentile(durations, 95) if durations else None,
                "maxDurationMs": max(durations) if durations else None,
                "lastFailure": failed_details[-1] if failed_details else None,
            }
        )
    return stats


def percentile(values: list[int], percent: int) -> int:
    if not values:
        raise ValueError("percentile requires at least one value")
    ordered = sorted(values)
    index = round((percent / 100) * (len(ordered) - 1))
    return ordered[index]


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


def write_reproduce_script(
    artifact_dir: Path,
    *,
    args: argparse.Namespace,
    required_checks: tuple[str, ...],
    route_probe_python: str,
) -> None:
    repo_root = Path.cwd()
    command = [
        sys.executable,
        "tools/scripts/synthetic_conversation_probe.py",
        "--base-url",
        args.base_url,
        "--caller",
        args.caller,
        "--callee",
        args.callee,
        "--iterations",
        str(args.iterations),
        "--artifact-dir",
        str(artifact_dir),
        "--command-timeout",
        str(args.command_timeout),
        "--route-probe-python",
        route_probe_python,
    ]
    if args.insecure:
        command.append("--insecure")
    for fixture_report in args.fixture_report:
        command.extend(["--fixture-report", fixture_report])
    for required_check in args.required_check:
        command.extend(["--required-check", required_check])
    if args.label:
        command.extend(["--label", args.label])

    script = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f"cd {shell_quote(str(repo_root))}\n"
        + " ".join(shell_quote(part) for part in command)
        + "\n"
    )
    path = artifact_dir / "reproduce.sh"
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise SystemExit(f"expected JSON object in {path}")
    return payload


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    raise SystemExit(main())
