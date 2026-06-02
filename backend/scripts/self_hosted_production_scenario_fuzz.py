#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_DATABASE_URL = "postgres://turbo_runtime:turbo_runtime@127.0.0.1:55432/turbo_runtime"
DEFAULT_REDIS_URL = "redis://127.0.0.1:56379/"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run production-shaped self-hosted scenario fuzz against real runtime processes."
    )
    parser.add_argument("--seed", type=int, default=123)
    parser.add_argument("--count", type=int, default=3)
    parser.add_argument(
        "--compose-file",
        default="backend/infra/self-hosted/docker-compose.yml",
    )
    parser.add_argument("--bind", default="127.0.0.1:18091")
    parser.add_argument("--database-url", default=DEFAULT_DATABASE_URL)
    parser.add_argument("--redis-url", default=DEFAULT_REDIS_URL)
    parser.add_argument(
        "--deterministic-report",
        default="/tmp/turbo-self-hosted-fuzz/in-memory-report.json",
    )
    parser.add_argument("--output", default="/tmp/turbo-self-hosted-fuzz/report.json")
    parser.add_argument("--service-timeout", type=float, default=45.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.run_id = str(time.time_ns())
    steps: list[dict[str, Any]] = []
    checks = deterministic_checks(Path(args.deterministic_report))

    preflight = run_command(
        "self-hosted-preflight",
        [
            sys.executable,
            "backend/scripts/self_hosted_infra_preflight.py",
            "--compose-file",
            args.compose_file,
            "--postgres-host",
            "127.0.0.1",
            "--postgres-port",
            "55432",
            "--redis-host",
            "127.0.0.1",
            "--redis-port",
            "56379",
            "--output",
            "/tmp/turbo-self-hosted-preflight.json",
        ],
    )
    steps.append(preflight)
    if not preflight["ok"]:
        return write_summary(args, steps, checks, "failed")

    compose_up = run_command(
        "compose-up",
        ["docker", "compose", "-f", args.compose_file, "up", "-d", "postgres", "redis"],
    )
    steps.append(compose_up)
    if not compose_up["ok"]:
        return write_summary(args, steps, checks, "failed")

    service_wait = wait_for_tcp("service-readiness", "127.0.0.1", 55432, args.service_timeout)
    redis_wait = wait_for_tcp("redis-readiness", "127.0.0.1", 56379, args.service_timeout)
    steps.extend([service_wait, redis_wait])
    if not service_wait["ok"] or not redis_wait["ok"]:
        return write_summary(args, steps, checks, "failed")

    postgres_wait = wait_for_postgres_query(args.compose_file, args.service_timeout)
    steps.append(postgres_wait)
    if not postgres_wait["ok"]:
        return write_summary(args, steps, checks, "failed")

    schema = apply_schema(args.compose_file)
    steps.append(schema)
    if not schema["ok"]:
        return write_summary(args, steps, checks, "failed")

    runtime = start_runtime(args)
    try:
        runtime_wait = wait_for_runtime(args.bind, args.service_timeout)
        steps.append(runtime_wait)
        if not runtime_wait["ok"]:
            return write_summary(args, steps, checks, "failed")

        for index in range(max(args.count, 1)):
            check = run_iteration(args, index)
            steps.append(check)
            if not check["ok"]:
                return write_summary(args, steps, checks, "failed")
            checks.append(f"production-runtime scenario iteration {index}")
    finally:
        stop_process(runtime)

    return write_summary(args, steps, checks, "ok")


def deterministic_checks(path: Path) -> list[str]:
    payload = read_json(path)
    checks = payload.get("checks") if isinstance(payload, dict) else None
    return [check for check in checks if isinstance(check, str)] if isinstance(checks, list) else []


def apply_schema(compose_file: str) -> dict[str, Any]:
    schema = Path("backend/infra/self-hosted/sql/001_runtime_schema.sql").read_text(encoding="utf-8")
    return run_command(
        "postgres-schema-application",
        [
            "docker",
            "compose",
            "-f",
            compose_file,
            "exec",
            "-T",
            "postgres",
            "psql",
            "-U",
            "turbo_runtime",
            "-d",
            "turbo_runtime",
            "-v",
            "ON_ERROR_STOP=1",
        ],
        input_text=schema,
    )


def start_runtime(args: argparse.Namespace) -> subprocess.Popen[str]:
    env = os.environ.copy()
    env.update(
        {
            "TURBO_RUNTIME_DATABASE_URL": args.database_url,
            "TURBO_RUNTIME_REDIS_URL": args.redis_url,
            "TURBO_RUNTIME_BIND": args.bind,
            "TURBO_RUNTIME_WEBSOCKET_MODE": "clustered-single-active",
            "TURBO_RUNTIME_ID": "runtime-a",
            "TURBO_RUNTIME_WEBSOCKET_OWNER_TTL_MS": "15000",
            "TURBO_REPO_ROOT": ".",
        }
    )
    return subprocess.Popen(
        ["cargo", "run", "-q", "-p", "beepbeep-runtime", "--bin", "beepbeep-runtime"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )


def wait_for_runtime(bind: str, timeout: float) -> dict[str, Any]:
    base_url = f"http://{bind}/s/turbo"
    deadline = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() <= deadline:
        try:
            body = fetch_json(f"{base_url}/v1/health", timeout=1.0)
            if body.get("status") == "ok" and body.get("runtime") == "self-hosted":
                config = fetch_json(f"{base_url}/v1/config", timeout=1.0)
                if config.get("mode") == "self-hosted" and config.get("supportsWebSocket") is True:
                    return {
                        "name": "runtime-health",
                        "ok": True,
                        "baseUrl": base_url,
                    }
                last_error = f"bad config {config!r}"
            else:
                last_error = f"bad health {body!r}"
        except Exception as error:  # noqa: BLE001 - probe should report any startup failure.
            last_error = str(error)
        time.sleep(0.5)
    return {
        "name": "runtime-health",
        "ok": False,
        "baseUrl": base_url,
        "error": last_error,
    }


def run_iteration(args: argparse.Namespace, index: int) -> dict[str, Any]:
    conversation_id = f"production-conversation-{args.seed}-{args.run_id}-{index}"
    operation_id = f"production-op-{args.seed}-{args.run_id}-{index}"
    seed = seed_conversation(args.compose_file, conversation_id)
    if not seed["ok"]:
        return {
            "name": f"production-runtime-scenario-{index}",
            "ok": False,
            "seedStep": seed,
        }

    base_url = f"http://{args.bind}"
    request = post_json(
        f"{base_url}/v1/conversations/{conversation_id}/talk-turns/request",
        request_talk_turn_command(conversation_id, operation_id),
    )
    if request.get("status") != "granted":
        return failed_iteration(index, "request-talk-turn did not grant", request)
    talk_turn_epoch = request.get("talkTurnEpoch")
    if not isinstance(talk_turn_epoch, int):
        return failed_iteration(index, "request-talk-turn omitted epoch", request)

    renew = post_json(
        f"{base_url}/v1/conversations/{conversation_id}/talk-turns/renew",
        renew_talk_turn_command(conversation_id, talk_turn_epoch, f"{operation_id}-renew"),
    )
    if renew.get("status") != "renewed":
        return failed_iteration(index, "renew-talk-turn did not renew", renew)
    duplicate_renew = post_json(
        f"{base_url}/v1/conversations/{conversation_id}/talk-turns/renew",
        renew_talk_turn_command(conversation_id, talk_turn_epoch, f"{operation_id}-renew"),
    )
    if duplicate_renew != renew:
        return failed_iteration(
            index,
            "duplicate renew-talk-turn was not idempotent",
            {"first": renew, "duplicate": duplicate_renew},
        )

    release = post_json(
        f"{base_url}/v1/conversations/{conversation_id}/talk-turns/release",
        release_talk_turn_command(conversation_id, talk_turn_epoch, f"{operation_id}-release"),
    )
    if release.get("status") != "released":
        return failed_iteration(index, "release-talk-turn did not release", release)
    duplicate_release = post_json(
        f"{base_url}/v1/conversations/{conversation_id}/talk-turns/release",
        release_talk_turn_command(conversation_id, talk_turn_epoch, f"{operation_id}-release"),
    )
    if duplicate_release != release:
        return failed_iteration(
            index,
            "duplicate release-talk-turn was not idempotent",
            {"first": release, "duplicate": duplicate_release},
        )

    remaining = scalar_sql(
        args.compose_file,
        (
            "select count(*) from runtime_current_talk_turns "
            f"where conversation_id = {sql_literal(conversation_id)};"
        ),
    )
    if remaining.get("stdout", "").strip() != "0":
        return failed_iteration(index, "current Talk Turn remained after release", remaining)

    next_operation_id = f"{operation_id}-next"
    next_request = post_json(
        f"{base_url}/v1/conversations/{conversation_id}/talk-turns/request",
        request_talk_turn_command(conversation_id, next_operation_id),
    )
    if next_request.get("status") != "granted":
        return failed_iteration(index, "second request-talk-turn did not grant", next_request)
    next_talk_turn_epoch = next_request.get("talkTurnEpoch")
    if not isinstance(next_talk_turn_epoch, int):
        return failed_iteration(index, "second request-talk-turn omitted epoch", next_request)
    if next_talk_turn_epoch == talk_turn_epoch:
        return failed_iteration(
            index,
            "second request-talk-turn reused stale epoch",
            {"firstEpoch": talk_turn_epoch, "nextRequest": next_request},
        )

    stale_release = post_json(
        f"{base_url}/v1/conversations/{conversation_id}/talk-turns/release",
        release_talk_turn_command(
            conversation_id,
            talk_turn_epoch,
            f"{operation_id}-stale-release",
        ),
    )
    if stale_release.get("_httpStatus", 200) < 400:
        return failed_iteration(
            index,
            "stale release after newer grant did not fail closed",
            stale_release,
        )

    active_after_stale_release = scalar_sql(
        args.compose_file,
        (
            "select talk_turn_epoch from runtime_current_talk_turns "
            f"where conversation_id = {sql_literal(conversation_id)};"
        ),
    )
    if active_after_stale_release.get("stdout", "").strip() != str(next_talk_turn_epoch):
        return failed_iteration(
            index,
            "stale release changed the active Talk Turn",
            {
                "staleRelease": stale_release,
                "activeAfterStaleRelease": active_after_stale_release,
                "expectedEpoch": next_talk_turn_epoch,
            },
        )

    return {
        "name": f"production-runtime-scenario-{index}",
        "ok": True,
        "conversationId": conversation_id,
        "request": request,
        "renew": renew,
        "duplicateRenew": duplicate_renew,
        "release": release,
        "duplicateRelease": duplicate_release,
        "nextRequest": next_request,
        "staleRelease": stale_release,
        "activeAfterStaleRelease": active_after_stale_release,
    }


def seed_conversation(compose_file: str, conversation_id: str) -> dict[str, Any]:
    sql = f"""
delete from runtime_conversations where conversation_id = {sql_literal(conversation_id)};
insert into runtime_conversations (conversation_id, conversation_seq, policy_version)
values ({sql_literal(conversation_id)}, 1, 'policy-v1');
insert into runtime_participants (conversation_id, participant_id, friend_id)
values
  ({sql_literal(conversation_id)}, 'participant-a', 'friend-a'),
  ({sql_literal(conversation_id)}, 'participant-b', 'friend-b');
insert into runtime_participant_devices (conversation_id, participant_id, device_id)
values
  ({sql_literal(conversation_id)}, 'participant-a', 'device-a'),
  ({sql_literal(conversation_id)}, 'participant-b', 'device-b');
insert into runtime_sessions (
  conversation_id, participant_id, device_id, session_epoch, last_seen_ms
) values
  ({sql_literal(conversation_id)}, 'participant-a', 'device-a', 0, 10000),
  ({sql_literal(conversation_id)}, 'participant-b', 'device-b', 7, 10000);
insert into runtime_device_presence (
  conversation_id, participant_id, device_id, observed_at_ms
) values
  ({sql_literal(conversation_id)}, 'participant-a', 'device-a', 10000),
  ({sql_literal(conversation_id)}, 'participant-b', 'device-b', 10000);
insert into runtime_device_audio_readiness (
  conversation_id, participant_id, device_id, session_epoch, observed_at_ms
) values
  ({sql_literal(conversation_id)}, 'participant-b', 'device-b', 7, 10000);
"""
    return run_psql(compose_file, "production-scenario-seed", sql)


def scalar_sql(compose_file: str, sql: str) -> dict[str, Any]:
    return run_command(
        "postgres-scalar-query",
        [
            "docker",
            "compose",
            "-f",
            compose_file,
            "exec",
            "-T",
            "postgres",
            "psql",
            "-U",
            "turbo_runtime",
            "-d",
            "turbo_runtime",
            "-t",
            "-A",
            "-v",
            "ON_ERROR_STOP=1",
        ],
        input_text=sql,
    )


def run_psql(compose_file: str, name: str, sql: str) -> dict[str, Any]:
    return run_command(
        name,
        [
            "docker",
            "compose",
            "-f",
            compose_file,
            "exec",
            "-T",
            "postgres",
            "psql",
            "-U",
            "turbo_runtime",
            "-d",
            "turbo_runtime",
            "-v",
            "ON_ERROR_STOP=1",
        ],
        input_text=sql,
    )


def request_talk_turn_command(conversation_id: str, operation_id: str) -> dict[str, Any]:
    return {
        "kind": "request-talk-turn",
        "conversationId": {"value": conversation_id},
        "requestingParticipantId": {"value": "participant-a"},
        "requestingDeviceId": {"value": "device-a"},
        "requestingSessionEpoch": {"value": 0},
        "targetParticipantId": {"value": "participant-b"},
        "operationId": operation_id,
        "policyVersion": {"value": "policy-v1"},
        "kernelVersion": {"value": "kernel-contract-v1"},
    }


def renew_talk_turn_command(
    conversation_id: str, talk_turn_epoch: int, operation_id: str
) -> dict[str, Any]:
    return {
        "kind": "renew-talk-turn",
        "conversationId": {"value": conversation_id},
        "participantId": {"value": "participant-a"},
        "deviceId": {"value": "device-a"},
        "talkTurnEpoch": {"value": talk_turn_epoch},
        "operationId": operation_id,
        "nowMs": 20000,
        "policyVersion": {"value": "policy-v1"},
        "maxTalkTurnLeaseMs": 15000,
        "grantsEnabled": True,
        "ownerRuntimeId": "runtime-a",
        "ownerEpoch": {"value": 1},
        "ownerLeaseExpiresAtMs": 60000,
    }


def release_talk_turn_command(
    conversation_id: str, talk_turn_epoch: int, operation_id: str
) -> dict[str, Any]:
    return {
        "kind": "release-talk-turn",
        "conversationId": {"value": conversation_id},
        "participantId": {"value": "participant-a"},
        "deviceId": {"value": "device-a"},
        "sessionEpoch": {"value": 0},
        "talkTurnEpoch": {"value": talk_turn_epoch},
        "operationId": operation_id,
        "policyVersion": {"value": "policy-v1"},
        "kernelVersion": {"value": "kernel-contract-v1"},
        "ownerRuntimeId": "runtime-a",
        "ownerEpoch": {"value": 1},
        "ownerLeaseExpiresAtMs": 60000,
    }


def post_json(url: str, payload: dict[str, Any]) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read().decode("utf-8", errors="replace")
            parsed = json.loads(text)
            parsed["_httpStatus"] = response.getcode()
            return parsed
    except urllib.error.HTTPError as error:
        text = error.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            parsed = {"error": text}
        parsed["_httpStatus"] = error.code
        return parsed


def fetch_json(url: str, timeout: float) -> dict[str, Any]:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def wait_for_tcp(name: str, host: str, port: int, timeout: float) -> dict[str, Any]:
    started = time.monotonic()
    deadline = started + timeout
    last_error = ""
    while time.monotonic() <= deadline:
        try:
            with socket.create_connection((host, port), timeout=1.0):
                return {
                    "name": name,
                    "ok": True,
                    "elapsedSeconds": round(time.monotonic() - started, 3),
                }
        except OSError as error:
            last_error = str(error)
            time.sleep(0.5)
    return {
        "name": name,
        "ok": False,
        "elapsedSeconds": round(time.monotonic() - started, 3),
        "error": last_error,
    }


def wait_for_postgres_query(compose_file: str, timeout: float) -> dict[str, Any]:
    started = time.monotonic()
    deadline = started + timeout
    last_result: dict[str, Any] | None = None
    while time.monotonic() <= deadline:
        result = run_command(
            "postgres-query-readiness",
            [
                "docker",
                "compose",
                "-f",
                compose_file,
                "exec",
                "-T",
                "postgres",
                "psql",
                "-U",
                "turbo_runtime",
                "-d",
                "turbo_runtime",
                "-t",
                "-A",
                "-v",
                "ON_ERROR_STOP=1",
                "-c",
                "select 1;",
            ],
        )
        last_result = result
        if result["ok"] and result.get("stdout", "").strip() == "1":
            return {
                "name": "postgres-query-readiness",
                "ok": True,
                "elapsedSeconds": round(time.monotonic() - started, 3),
            }
        time.sleep(0.5)
    return {
        "name": "postgres-query-readiness",
        "ok": False,
        "elapsedSeconds": round(time.monotonic() - started, 3),
        "lastResult": last_result,
    }


def failed_iteration(index: int, reason: str, detail: Any) -> dict[str, Any]:
    return {
        "name": f"production-runtime-scenario-{index}",
        "ok": False,
        "reason": reason,
        "detail": detail,
    }


def run_command(
    name: str, command: list[str], *, input_text: str | None = None
) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        input=input_text,
        capture_output=True,
        text=True,
        check=False,
    )
    return {
        "name": name,
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "command": command,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def write_summary(
    args: argparse.Namespace,
    steps: list[dict[str, Any]],
    checks: list[str],
    status: str,
) -> int:
    ok = status == "ok"
    summary = {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "gate": "self-hosted-scenario-fuzz-local",
        "seed": args.seed,
        "requested_count": args.count,
        "checks": checks,
        "status": status,
        "ok": ok,
        "substrate": "production-runtime-postgres-redis",
        "steps": steps,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"self-hosted production scenario fuzz status: {status}")
    print(f"self-hosted production scenario fuzz artifact: {output}")
    return 0 if ok else 1


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


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
