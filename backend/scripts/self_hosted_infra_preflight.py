#!/usr/bin/env python3

from __future__ import annotations

import argparse
import struct
import json
import shutil
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check whether local self-hosted runtime infrastructure can start."
    )
    parser.add_argument(
        "--compose-file",
        default="backend/infra/self-hosted/docker-compose.yml",
        help="Docker Compose file for local self-hosted runtime dependencies.",
    )
    parser.add_argument(
        "--output",
        default="/tmp/turbo-self-hosted-preflight.json",
        help="JSON artifact path.",
    )
    parser.add_argument("--postgres-host", default="127.0.0.1")
    parser.add_argument("--postgres-port", type=int, default=55432)
    parser.add_argument("--redis-host", default="127.0.0.1")
    parser.add_argument("--redis-port", type=int, default=56379)
    parser.add_argument("--command-timeout", type=float, default=8.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    compose_file = Path(args.compose_file)
    steps: list[dict[str, Any]] = []

    docker_path = shutil.which("docker")
    steps.append(
        {
            "name": "docker-cli",
            "ok": docker_path is not None,
            "path": docker_path,
        }
    )

    steps.append(
        {
            "name": "compose-file",
            "ok": compose_file.exists(),
            "path": str(compose_file),
        }
    )

    docker_daemon: dict[str, Any]
    if docker_path and compose_file.exists():
        steps.append(
            run_command(
                "compose-config",
                [docker_path, "compose", "-f", str(compose_file), "config", "-q"],
                timeout=args.command_timeout,
            )
        )
        docker_daemon = run_command(
            "docker-daemon",
            [docker_path, "info", "--format", "{{json .ServerVersion}}"],
            timeout=args.command_timeout,
        )
        if docker_daemon.get("timedOut") is True:
            socket_probe = check_docker_socket("docker-daemon-socket")
            socket_probe["fallbackFor"] = "docker-daemon"
            docker_daemon = socket_probe
        steps.append(docker_daemon)
    else:
        steps.append(
            {
                "name": "compose-config",
                "ok": False,
                "skipped": True,
                "reason": "docker CLI or compose file missing",
            }
        )
        docker_daemon = {
            "name": "docker-daemon",
            "ok": False,
            "skipped": True,
            "reason": "docker CLI or compose file missing",
        }
        steps.append(docker_daemon)

    postgres_tcp = check_tcp("postgres-tcp", args.postgres_host, args.postgres_port)
    redis_tcp = check_tcp("redis-tcp", args.redis_host, args.redis_port)
    postgres_protocol = check_postgres_protocol(
        "postgres-protocol", args.postgres_host, args.postgres_port
    )
    redis_protocol = check_redis_protocol("redis-protocol", args.redis_host, args.redis_port)
    steps.append(postgres_tcp)
    steps.append(redis_tcp)
    steps.append(postgres_protocol)
    steps.append(redis_protocol)

    compose_ok = any(step["name"] == "compose-config" and step.get("ok") is True for step in steps)
    docker_ready = compose_ok and docker_daemon.get("ok") is True
    existing_services_ready = (
        postgres_tcp.get("ok") is True
        and redis_tcp.get("ok") is True
        and postgres_protocol.get("ok") is True
        and redis_protocol.get("ok") is True
    )
    ok = docker_ready or existing_services_ready
    substrate = "docker-compose" if docker_ready else "existing-services" if existing_services_ready else "unavailable"
    summary = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "status": "pass" if ok else "fail",
        "ok": ok,
        "substrate": substrate,
        "dockerReady": docker_ready,
        "existingServicesReady": existing_services_ready,
        "composeFile": str(compose_file),
        "postgres": {"host": args.postgres_host, "port": args.postgres_port},
        "redis": {"host": args.redis_host, "port": args.redis_port},
        "steps": steps,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"self-hosted preflight status: {summary['status']}")
    print(f"self-hosted preflight artifact: {output}")
    return 0 if ok else 1


def run_command(name: str, command: list[str], *, timeout: float = 8.0) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        return {
            "name": name,
            "ok": False,
            "exitCode": None,
            "timedOut": True,
            "timeoutSeconds": timeout,
            "command": command,
            "stdout": (error.stdout or "").strip()
            if isinstance(error.stdout, str)
            else "",
            "stderr": (error.stderr or "").strip()
            if isinstance(error.stderr, str)
            else "",
        }
    return {
        "name": name,
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "command": command,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def check_docker_socket(name: str, socket_path: str = "/var/run/docker.sock") -> dict[str, Any]:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(2.0)
            connection.connect(socket_path)
            connection.sendall(
                b"GET /_ping HTTP/1.1\r\n"
                b"Host: docker\r\n"
                b"Connection: close\r\n"
                b"\r\n"
            )
            response = connection.recv(256)
        ok = b"200 OK" in response and response.rstrip().endswith(b"OK")
        return {
            "name": name,
            "ok": ok,
            "socket": socket_path,
            "responsePreview": response.decode("utf-8", errors="replace")[:120],
        }
    except OSError as error:
        return {
            "name": name,
            "ok": False,
            "socket": socket_path,
            "error": str(error),
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


def check_postgres_protocol(name: str, host: str, port: int) -> dict[str, Any]:
    try:
        with socket.create_connection((host, port), timeout=1.0) as connection:
            connection.settimeout(1.0)
            ssl_request = struct.pack("!II", 8, 80877103)
            connection.sendall(ssl_request)
            response = connection.recv(1)
            ok = response in {b"S", b"N"}
            return {
                "name": name,
                "ok": ok,
                "host": host,
                "port": port,
                "response": response.decode("ascii", errors="replace"),
            }
    except OSError as error:
        return {
            "name": name,
            "ok": False,
            "host": host,
            "port": port,
            "error": str(error),
        }


def check_redis_protocol(name: str, host: str, port: int) -> dict[str, Any]:
    try:
        with socket.create_connection((host, port), timeout=1.0) as connection:
            connection.settimeout(1.0)
            connection.sendall(b"*1\r\n$4\r\nPING\r\n")
            response = connection.recv(128)
            ok = response.startswith(b"+PONG") or response.startswith(b"-NOAUTH")
            return {
                "name": name,
                "ok": ok,
                "host": host,
                "port": port,
                "responsePreview": response.decode("utf-8", errors="replace")[:80],
            }
    except OSError as error:
        return {
            "name": name,
            "ok": False,
            "host": host,
            "port": port,
            "error": str(error),
        }


if __name__ == "__main__":
    raise SystemExit(main())
