#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path


RUNTIME_CONFIG_PATH = Path("/tmp/turbo-debug/hosted_backend_client_probe_runtime.json")
DEFAULT_OUTPUT_PATH = Path("/tmp/turbo-debug/hosted_backend_client_probe_latest.json")
DEFAULT_DESTINATION = "platform=iOS Simulator,name=iPhone 17 Pro"
TEST_NAME = "hostedBackendClientWebSocketProbeStaysConnectedUnderHeartbeatAndTelemetryLoad"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the hosted iOS backend client WebSocket probe through the targeted Swift test wrapper."
    )
    parser.add_argument("--base-url", default="https://api.beepbeep.to")
    parser.add_argument("--duration", type=int, default=60)
    parser.add_argument("--heartbeat-interval", type=int, default=20)
    parser.add_argument("--telemetry-interval", type=int, default=20)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT_PATH))
    parser.add_argument("--destination", default=DEFAULT_DESTINATION)
    parser.add_argument("--lock-file", default="/tmp/turbo-hosted-backend-client-probe.lock")
    parser.add_argument("--derived-data", default="/tmp/turbo-dd-hosted-backend-client-probe")
    return parser.parse_args()


def write_runtime_config(args: argparse.Namespace) -> None:
    suffix = uuid.uuid4().hex
    payload = {
        "enabledUntilEpochSeconds": time.time() + 3600,
        "baseURL": args.base_url,
        "handle": f"@wsprobe{suffix[:10]}",
        "deviceID": f"ios-client-probe-{suffix[:12]}",
        "durationSeconds": args.duration,
        "heartbeatIntervalSeconds": args.heartbeat_interval,
        "telemetryIntervalSeconds": args.telemetry_interval,
        "outputPath": args.output,
        "suppressSharedAppBackendBootstrap": True,
    }
    RUNTIME_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    RUNTIME_CONFIG_PATH.write_text(json.dumps(payload), encoding="utf-8")


def run_probe(args: argparse.Namespace) -> int:
    output_path = Path(args.output)
    output_path.unlink(missing_ok=True)
    write_runtime_config(args)
    command = [
        sys.executable,
        "tools/scripts/run_targeted_swift_tests.py",
        "--lock-file",
        args.lock_file,
        "--derived-data",
        args.derived_data,
        "--destination",
        args.destination,
        "--name",
        TEST_NAME,
    ]
    try:
        completed = subprocess.run(command, check=False)
        if completed.returncode != 0:
            return completed.returncode
        if not output_path.is_file() or output_path.stat().st_size == 0:
            print(
                f"hosted backend client probe did not produce artifact: {output_path}",
                file=sys.stderr,
            )
            return 1
        return 0
    finally:
        RUNTIME_CONFIG_PATH.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    return run_probe(args)


if __name__ == "__main__":
    raise SystemExit(main())
