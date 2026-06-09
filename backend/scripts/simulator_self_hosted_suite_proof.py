#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import ssl
import urllib.error
import urllib.request
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run and record the simulator scenario suite against a self-hosted runtime."
    )
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:8091/s/turbo",
        help="Self-hosted runtime base URL exposed to the app target.",
    )
    parser.add_argument("--scenario", default="", help="Optional comma-separated scenario filter.")
    parser.add_argument("--handle-a", default="@avery")
    parser.add_argument("--handle-b", default="@blake")
    parser.add_argument("--output", default="/tmp/turbo-simulator-self-hosted-suite.json")
    parser.add_argument("--preflight-timeout", type=float, default=3.0)
    parser.add_argument("--insecure", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    suffix = uuid.uuid4().hex
    device_id_a = f"sim-self-hosted-avery-{suffix}"
    device_id_b = f"sim-self-hosted-blake-{suffix}"
    preflight_step = health_preflight(args.base_url, args.preflight_timeout, args.insecure)

    if preflight_step["ok"]:
        scenario_step = run_command(
            "simulator-scenario-suite-self-hosted",
            [
                "python3",
                "tools/scripts/run_simulator_scenarios.py",
                "--scenario",
                args.scenario,
                "--base-url",
                args.base_url,
                "--handle-a",
                args.handle_a,
                "--handle-b",
                args.handle_b,
                "--device-id-a",
                device_id_a,
                "--device-id-b",
                device_id_b,
            ],
        )
    else:
        scenario_step = skipped_step(
            "simulator-scenario-suite-self-hosted",
            "self-hosted runtime health preflight failed",
        )

    if scenario_step["ok"]:
        diagnostics_command = [
            "python3",
            "tools/scripts/merged_diagnostics.py",
            "--base-url",
            args.base_url,
            "--no-telemetry",
            "--fail-on-violations",
            "--device",
            f"{args.handle_a}={device_id_a}",
            "--device",
            f"{args.handle_b}={device_id_b}",
        ]
        if args.insecure:
            diagnostics_command.append("--insecure")
        diagnostics_step = run_command(
            "simulator-self-hosted-merged-diagnostics-strict",
            diagnostics_command,
        )
    else:
        diagnostics_step = skipped_step(
            "simulator-self-hosted-merged-diagnostics-strict",
            "simulator scenario suite failed",
        )

    steps = [preflight_step, scenario_step, diagnostics_step]
    ok = all(step.get("ok") is True for step in steps)
    summary = {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "status": "pass" if ok else "fail",
        "ok": ok,
        "baseUrl": args.base_url,
        "scenario": args.scenario,
        "handleA": args.handle_a,
        "handleB": args.handle_b,
        "deviceIDA": device_id_a,
        "deviceIDB": device_id_b,
        "steps": steps,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"simulator self-hosted suite status: {summary['status']}")
    print(f"simulator self-hosted suite artifact: {output}")
    return 0 if ok else 1


def run_command(name: str, command: list[str]) -> dict[str, Any]:
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    return {
        "name": name,
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "command": command,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def health_preflight(base_url: str, timeout: float, insecure: bool = False) -> dict[str, Any]:
    health_url = base_url.rstrip("/") + "/v1/health"
    config_url = base_url.rstrip("/") + "/v1/config"
    started_at = utc_now()
    health = fetch_json(health_url, timeout, insecure=insecure)
    config = fetch_json(config_url, timeout, insecure=insecure)
    checks = [
        {
            "name": "health",
            **health,
            "ok": health.get("ok") is True
            and health.get("httpCode") == 200
            and health.get("body", {}).get("status") == "ok"
            and health.get("body", {}).get("runtime") == "self-hosted",
        },
        {
            "name": "config",
            **config,
            "ok": config.get("ok") is True
            and config.get("httpCode") == 200
            and config.get("body", {}).get("mode") == "self-hosted"
            and config_has_runtime_http_control(config.get("body", {}))
            and config.get("body", {}).get("supportsWebSocket") is not True,
        },
    ]
    ok = all(check["ok"] is True for check in checks)
    result = {
        "name": "self-hosted-health-preflight",
        "ok": ok,
        "startedAt": started_at,
        "checks": checks,
    }
    if not ok:
        result["reason"] = "self-hosted health/config preflight failed"
    return result


def config_has_runtime_http_control(body: dict[str, Any]) -> bool:
    runtime_control = body.get("runtimeControl")
    if not isinstance(runtime_control, dict):
        return False
    http = runtime_control.get("http")
    return isinstance(http, dict) and http.get("supported") is True


def fetch_json(url: str, timeout: float, *, insecure: bool = False) -> dict[str, Any]:
    context = ssl._create_unverified_context() if insecure else None
    try:
        with urllib.request.urlopen(url, timeout=timeout, context=context) as response:
            body_text = response.read().decode("utf-8", errors="replace")
            status_code = response.getcode()
    except (OSError, urllib.error.URLError) as error:
        return {
            "ok": False,
            "url": url,
            "error": str(error),
        }
    try:
        body = json.loads(body_text)
    except json.JSONDecodeError as error:
        return {
            "ok": False,
            "url": url,
            "httpCode": status_code,
            "responsePreview": body_text[:240],
            "error": str(error),
        }
    return {
        "url": url,
        "httpCode": status_code,
        "body": body if isinstance(body, dict) else {},
        "ok": isinstance(body, dict),
        "responsePreview": body_text[:240],
    }


def skipped_step(name: str, reason: str) -> dict[str, Any]:
    return {
        "name": name,
        "ok": False,
        "skipped": True,
        "reason": reason,
    }


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
