#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_OUTPUT = "/tmp/turbo-runtime-control-probe.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Probe the current runtime-control lanes: QUIC, TLS, HTTP, and retired WebSocket config."
    )
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    started_at = utc_now()
    checks = [
        run_check(
            "runtime-quic-control",
            ["cargo", "test", "-q", "-p", "beepbeep-runtime", "runtime_quic"],
        ),
        run_check(
            "runtime-tls-control",
            ["cargo", "test", "-q", "-p", "beepbeep-runtime", "runtime_tls"],
        ),
        run_check(
            "persistent-control-stream",
            ["cargo", "test", "-q", "-p", "beepbeep-runtime", "persistent_control_stream"],
        ),
        run_check(
            "runtime-http-bootstrap-recovery",
            ["cargo", "test", "-q", "-p", "beepbeep-runtime", "self_hosted_http_process_probe"],
        ),
        run_check(
            "runtime-websocket-retired-by-default",
            [
                "cargo",
                "test",
                "-q",
                "-p",
                "beepbeep-runtime",
                "self_hosted_config_retires_runtime_websocket_by_default",
            ],
        ),
    ]
    ok = all(check["ok"] for check in checks)
    report = {
        "schemaVersion": 1,
        "status": "ok" if ok else "fail",
        "ok": ok,
        "startedAt": started_at,
        "endedAt": utc_now(),
        "checks": checks,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"runtime control probe status: {report['status']}")
    print(f"runtime control probe artifact: {output}")
    return 0 if ok else 1


def run_check(name: str, command: list[str]) -> dict[str, Any]:
    started = time.perf_counter()
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    return {
        "name": name,
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "durationMs": int((time.perf_counter() - started) * 1000),
        "command": command,
        "stdoutTail": tail(completed.stdout),
        "stderrTail": tail(completed.stderr),
    }


def tail(value: str, limit: int = 4000) -> str:
    return value[-limit:]


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
