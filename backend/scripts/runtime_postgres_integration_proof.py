#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REQUIRED_PROOFS = [
    {
        "name": "postgres-schema-application",
        "description": "runtime SQL schema applies to the live Postgres service",
    },
    {
        "name": "postgres-snapshot-loader",
        "description": "snapshot loader builds kernel input from live Conversation, Participant, Device, Session, Presence, and Readiness rows",
    },
    {
        "name": "talk-turn-db-constraints",
        "description": "Postgres enforces one current Talk Turn per Conversation",
    },
    {
        "name": "kernel-replay-idempotency",
        "description": "kernel replay facts fence duplicate operation ids per route",
    },
    {
        "name": "post-commit-outbox-delivery",
        "description": "post-commit effect rows are delivered only after commit and marked delivered after sink success",
    },
    {
        "name": "websocket-authorization-facts",
        "description": "durable WebSocket authorization facts are persisted and queryable",
    },
    {
        "name": "durable-remembered-contacts",
        "description": "remembered contacts are stored reciprocally in Postgres and survive separate runtime store instances",
    },
    {
        "name": "durable-profiles",
        "description": "profile names are stored in Postgres and survive separate runtime store instances",
    },
    {
        "name": "durable-beep-threads",
        "description": "Beep Threads, pending projections, and stale-action aliases are stored in Postgres and survive separate runtime store instances",
    },
    {
        "name": "redis-owner-record-cas",
        "description": "Redis owner-record CAS accepts fresh leases, rejects stale leases, accepts drain, decodes records, and cleans up keys",
    },
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run and record the Rust runtime Postgres integration proof."
    )
    parser.add_argument(
        "--compose-file",
        default="backend/infra/self-hosted/docker-compose.yml",
        help="Docker Compose file for local self-hosted runtime dependencies.",
    )
    parser.add_argument(
        "--database-url",
        default="postgres://turbo_runtime:turbo_runtime@127.0.0.1:55432/turbo_runtime",
        help="Postgres URL used by the ignored runtime integration test.",
    )
    parser.add_argument(
        "--redis-url",
        default="redis://127.0.0.1:56379/",
        help="Redis URL used by the ignored runtime integration test.",
    )
    parser.add_argument(
        "--preflight-output",
        default="/tmp/turbo-self-hosted-preflight.json",
        help="Preflight JSON artifact path.",
    )
    parser.add_argument(
        "--output",
        default="/tmp/turbo-rust-runtime-integration.json",
        help="Integration proof JSON artifact path.",
    )
    parser.add_argument("--postgres-host", default="127.0.0.1")
    parser.add_argument("--postgres-port", type=int, default=55432)
    parser.add_argument("--redis-host", default="127.0.0.1")
    parser.add_argument("--redis-port", type=int, default=56379)
    parser.add_argument("--service-timeout", type=float, default=30.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    steps: list[dict[str, Any]] = []

    preflight = run_command(
        "self-hosted-preflight",
            [
                sys.executable,
                "backend/scripts/self_hosted_infra_preflight.py",
                "--compose-file",
                args.compose_file,
                "--postgres-host",
                args.postgres_host,
                "--postgres-port",
                str(args.postgres_port),
                "--redis-host",
                args.redis_host,
                "--redis-port",
                str(args.redis_port),
                "--output",
                args.preflight_output,
            ],
    )
    steps.append(preflight)
    preflight_payload = read_json(Path(args.preflight_output))
    substrate = preflight_payload.get("substrate") if isinstance(preflight_payload, dict) else None

    if preflight["ok"] and substrate == "docker-compose":
        compose_up = run_command(
            "compose-up",
            ["docker", "compose", "-f", args.compose_file, "up", "-d", "postgres", "redis"],
        )
    elif preflight["ok"] and substrate == "existing-services":
        compose_up = {
            "name": "compose-up",
            "ok": True,
            "skipped": True,
            "reason": "using already-running Postgres/Redis services",
        }
    else:
        compose_up = skipped_step("compose-up", "self-hosted preflight failed")
    steps.append(compose_up)

    if compose_up["ok"]:
        service_wait = wait_for_services(args)
    else:
        service_wait = skipped_step("service-readiness", "compose-up did not complete")
    steps.append(service_wait)

    if service_wait["ok"]:
        env = os.environ.copy()
        env["TURBO_RUNTIME_DATABASE_URL"] = args.database_url
        env["TURBO_RUNTIME_REDIS_URL"] = args.redis_url
        integration_test = run_command(
            "request-talk-turn-postgres-redis-integration-test",
            [
                "cargo",
                "test",
                "-q",
                "-p",
                "beepbeep-runtime",
                "--test",
                "request_talk_turn_integration",
                "--",
                "--ignored",
            ],
            env=env,
        )
    else:
        integration_test = skipped_step(
            "request-talk-turn-postgres-redis-integration-test",
            "Postgres/Redis services were not reachable",
        )
    steps.append(integration_test)

    summary = build_summary(args, steps)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"runtime Postgres integration status: {summary['status']}")
    print(f"runtime Postgres integration artifact: {output}")
    return 0 if summary["ok"] else 1


def build_summary(args: argparse.Namespace, steps: list[dict[str, Any]]) -> dict[str, Any]:
    required_proofs = integration_proofs(steps)
    ok = all(step.get("ok") is True for step in steps) and all(
        proof["status"] == "pass" for proof in required_proofs
    )
    return {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "status": "pass" if ok else "fail",
        "ok": ok,
        "composeFile": args.compose_file,
        "databaseUrl": args.database_url,
        "redisUrl": args.redis_url,
        "preflightArtifact": args.preflight_output,
        "postgres": {"host": args.postgres_host, "port": args.postgres_port},
        "redis": {"host": args.redis_host, "port": args.redis_port},
        "requiredProofs": required_proofs,
        "steps": steps,
    }


def integration_proofs(steps: list[dict[str, Any]]) -> list[dict[str, Any]]:
    integration_step = next(
        (
            step
            for step in steps
            if step.get("name") == "request-talk-turn-postgres-redis-integration-test"
        ),
        None,
    )
    integration_passed = integration_step is not None and integration_step.get("ok") is True
    reason = (
        "integration test passed"
        if integration_passed
        else integration_blocked_reason(integration_step)
    )
    return [
        {
            **proof,
            "status": "pass" if integration_passed else "blocked",
            "ok": integration_passed,
            "sourceStep": "request-talk-turn-postgres-redis-integration-test",
            "reason": reason,
        }
        for proof in REQUIRED_PROOFS
    ]


def integration_blocked_reason(integration_step: dict[str, Any] | None) -> str:
    if integration_step is None:
        return "integration test step missing"
    if integration_step.get("skipped") is True:
        return str(integration_step.get("reason") or "integration test skipped")
    return str(integration_step.get("stderr") or integration_step.get("reason") or "integration test failed")


def run_command(
    name: str,
    command: list[str],
    *,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    return {
        "name": name,
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "command": command,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def skipped_step(name: str, reason: str) -> dict[str, Any]:
    return {
        "name": name,
        "ok": False,
        "skipped": True,
        "reason": reason,
    }


def wait_for_services(args: argparse.Namespace) -> dict[str, Any]:
    started = time.monotonic()
    observations: list[dict[str, Any]] = []
    deadline = started + args.service_timeout
    while time.monotonic() <= deadline:
        postgres = check_tcp("postgres-tcp", args.postgres_host, args.postgres_port)
        redis = check_tcp("redis-tcp", args.redis_host, args.redis_port)
        observations = [postgres, redis]
        if postgres["ok"] and redis["ok"]:
            return {
                "name": "service-readiness",
                "ok": True,
                "elapsedSeconds": round(time.monotonic() - started, 3),
                "checks": observations,
            }
        time.sleep(0.5)
    return {
        "name": "service-readiness",
        "ok": False,
        "elapsedSeconds": round(time.monotonic() - started, 3),
        "checks": observations,
    }


def check_tcp(name: str, host: str, port: int) -> dict[str, Any]:
    try:
        with socket.create_connection((host, port), timeout=1.0):
            return {
                "name": name,
                "ok": True,
                "host": host,
                "port": port,
            }
    except OSError as error:
        return {
            "name": name,
            "ok": False,
            "host": host,
            "port": port,
            "error": str(error),
        }


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
