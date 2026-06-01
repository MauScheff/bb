#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_ZONE = "europe-west6-a"
DEFAULT_INSTANCE = "turbo-self-hosted-1"
DEFAULT_REMOTE_DIR = "/opt/turbo-self-hosted"
DEFAULT_OUTPUT = "/tmp/turbo-gce-self-hosted-deploy.json"
RELEASE_ROOTS = [
    "Cargo.toml",
    "Cargo.lock",
    "backend/runtime",
    "backend/relay",
    "backend/infra/self-hosted",
    "backend/infra/vm/Dockerfile",
    "backend/infra/vm/docker-compose.yml",
    "backend/infra/vm/build/kernel",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Deploy the self-hosted Turbo runtime to one Compute Engine VM."
    )
    parser.add_argument("--project", default=os.environ.get("TURBO_GCE_PROJECT", ""))
    parser.add_argument("--zone", default=os.environ.get("TURBO_GCE_ZONE", DEFAULT_ZONE))
    parser.add_argument("--instance", default=os.environ.get("TURBO_GCE_INSTANCE", DEFAULT_INSTANCE))
    parser.add_argument("--remote-dir", default=os.environ.get("TURBO_GCE_REMOTE_DIR", DEFAULT_REMOTE_DIR))
    parser.add_argument("--image-tag", default=os.environ.get("TURBO_GCE_IMAGE_TAG", ""))
    parser.add_argument("--runtime-port", default=os.environ.get("TURBO_RUNTIME_PORT", "8091"))
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument("--include-relay", action="store_true")
    parser.add_argument("--skip-kernel-compile", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    project = args.project or gcloud_project()
    image_tag = args.image_tag or git_short_sha()
    release_name = f"turbo-self-hosted-{image_tag}"
    release_archive = repo_root / "backend" / "infra" / "vm" / "build" / f"{release_name}.tar.gz"
    remote_archive = f"/tmp/{release_name}.tar.gz"
    image = f"turbo-self-hosted:{image_tag}"
    steps: list[dict[str, Any]] = []

    required = {
        "project": project,
        "zone": args.zone,
        "instance": args.instance,
        "remoteDir": args.remote_dir,
    }
    steps.extend(tool_preflight())
    steps.append({"name": "deploy-config", "ok": all(required.values()), "values": required})

    if not args.skip_kernel_compile:
        steps.append(run_step("kernel-compile", kernel_compile_command(), dry_run=args.dry_run))

    steps.append(
        create_release_archive(
            repo_root=repo_root,
            archive_path=release_archive,
            dry_run=args.dry_run,
        )
    )
    steps.append(
        run_step(
            "copy-release-to-vm",
            gcloud_compute_scp_command(
                project=project,
                zone=args.zone,
                instance=args.instance,
                source=str(release_archive),
                destination=f"{args.instance}:{remote_archive}",
            ),
            dry_run=args.dry_run,
        )
    )
    remote_script = build_remote_deploy_script(
        remote_dir=args.remote_dir,
        remote_archive=remote_archive,
        release_name=release_name,
        image=image,
        runtime_port=args.runtime_port,
        include_relay=args.include_relay,
    )
    steps.append(
        run_step(
            "remote-compose-up",
            gcloud_compute_ssh_command(
                project=project,
                zone=args.zone,
                instance=args.instance,
                remote_script=remote_script,
            ),
            dry_run=args.dry_run,
            extra={"remoteScript": remote_script},
        )
    )

    ok = all(step.get("ok") is True for step in steps)
    summary = {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "status": "pass" if ok else "fail",
        "ok": ok,
        "dryRun": args.dry_run,
        "project": project,
        "zone": args.zone,
        "instance": args.instance,
        "remoteDir": args.remote_dir,
        "release": release_name,
        "image": image,
        "includeRelay": args.include_relay,
        "kernelPackaging": {
            "mode": "compiled-uc-artifacts",
            "productionRecommended": True,
            "note": "UCM is used to execute sealed .uc artifacts; no live Unison codebase is packaged into the VM image.",
        },
        "services": ["postgres", "redis", "runtime"] + (["relay"] if args.include_relay else []),
        "steps": steps,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"gce self-hosted deploy status: {summary['status']}")
    print(f"gce self-hosted deploy artifact: {output}")
    return 0 if ok else 1


def kernel_compile_command() -> list[str]:
    return [
        "python3",
        "backend/scripts/compile_unison_kernel_artifacts.py",
        "--output-dir",
        "backend/infra/vm/build/kernel",
        "--summary",
        "/tmp/turbo-kernel-compile.json",
    ]


def create_release_archive(*, repo_root: Path, archive_path: Path, dry_run: bool) -> dict[str, Any]:
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    if dry_run:
        return {
            "name": "create-release-archive",
            "ok": True,
            "dryRun": True,
            "archive": str(archive_path),
        }
    with tarfile.open(archive_path, "w:gz") as archive:
        for path in archive_paths(repo_root, archive_path):
            if should_exclude(path, repo_root, archive_path):
                continue
            archive.add(path, arcname=path.relative_to(repo_root))
    return {
        "name": "create-release-archive",
        "ok": True,
        "archive": str(archive_path),
        "bytes": archive_path.stat().st_size,
    }


def archive_paths(repo_root: Path, archive_path: Path) -> list[Path]:
    paths: list[Path] = []
    for release_root in RELEASE_ROOTS:
        root_candidate = repo_root / release_root
        if not root_candidate.exists():
            continue
        if root_candidate.is_file():
            paths.append(root_candidate)
            continue
        collect_archive_tree(root_candidate, repo_root, archive_path, paths)
    return sorted(set(paths))


def collect_archive_tree(
    start: Path,
    repo_root: Path,
    archive_path: Path,
    paths: list[Path],
) -> None:
    for root, dirs, files in os.walk(start):
        root_path = Path(root)
        dirs[:] = [
            dirname
            for dirname in dirs
            if not should_prune_dir(root_path / dirname, repo_root)
        ]
        for filename in files:
            path = root_path / filename
            if not should_exclude(path, repo_root, archive_path):
                paths.append(path)


def should_prune_dir(path: Path, repo_root: Path) -> bool:
    relative = path.relative_to(repo_root)
    if relative.parts == ("backend", "infra", "vm", "build"):
        return False
    if relative.parts[:4] == ("backend", "infra", "vm", "build"):
        return relative.parts[:5] != (
            "backend",
            "infra",
            "vm",
            "build",
            "kernel",
        )
    if relative.parts[:5] == (
        "backend",
        "infra",
        "vm",
        "build",
        "kernel",
    ):
        return False
    if relative.name in {
        ".git",
        ".scenario-diagnostics",
        ".venv",
        ".wrangler",
        "DerivedData",
        "__pycache__",
        "build",
        "node_modules",
        "target",
    }:
        return True
    return False


def should_exclude(path: Path, repo_root: Path, archive_path: Path) -> bool:
    relative = path.relative_to(repo_root)
    parts = set(relative.parts)
    if path == archive_path:
        return True
    if relative.name in {".DS_Store", ".envrc", ".unisonHistory"}:
        return True
    if relative.parts[:5] == (
        "backend",
        "infra",
        "vm",
        "build",
        "kernel",
    ):
        return False
    if relative.parts[:4] == ("backend", "infra", "vm", "build"):
        return True
    if parts & {
        ".git",
        ".scenario-diagnostics",
        ".venv",
        ".wrangler",
        "DerivedData",
        "__pycache__",
        "build",
        "node_modules",
        "target",
    }:
        return True
    if relative.name == ".scenario-runtime-config.json":
        return True
    return False


def build_remote_deploy_script(
    *,
    remote_dir: str,
    remote_archive: str,
    release_name: str,
    image: str,
    runtime_port: str,
    include_relay: bool,
) -> str:
    remote_dir_q = shlex.quote(remote_dir)
    remote_archive_q = shlex.quote(remote_archive)
    release_name_q = shlex.quote(release_name)
    image_q = shlex.quote(image)
    runtime_port_q = shlex.quote(runtime_port)
    services = "postgres redis runtime relay" if include_relay else "postgres redis runtime"
    profiles = "COMPOSE_PROFILES=relay " if include_relay else ""
    optional_runtime_env = {
        key: os.environ.get(key, "")
        for key in [
            "TURBO_APNS_WORKER_BASE_URL",
            "TURBO_APNS_WORKER_SECRET",
            "TURBO_APNS_BUNDLE_ID",
            "TURBO_APNS_USE_SANDBOX",
            "TURBO_APNS_WORKER_TIMEOUT_MS",
        ]
    }
    optional_runtime_env_script = "\n".join(
        f"upsert_env {shlex.quote(key)} {shlex.quote(value)}"
        for key, value in optional_runtime_env.items()
        if value
    )
    return f"""set -euo pipefail
REMOTE_DIR={remote_dir_q}
RELEASE_NAME={release_name_q}
RELEASE_DIR="$REMOTE_DIR/releases/$RELEASE_NAME"
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg openssl
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo rm -rf "$RELEASE_DIR"
sudo mkdir -p "$RELEASE_DIR" "$REMOTE_DIR/releases"
sudo tar -xzf {remote_archive_q} -C "$RELEASE_DIR"
sudo ln -sfn "$RELEASE_DIR" "$REMOTE_DIR/current"
if [ ! -f "$REMOTE_DIR/.env" ]; then
  PASSWORD="$(openssl rand -hex 24 2>/dev/null || date +%s | sha256sum | cut -c1-48)"
  sudo install -m 600 /dev/null "$REMOTE_DIR/.env"
  {{
    echo "POSTGRES_DB=turbo_runtime"
    echo "POSTGRES_USER=turbo_runtime"
    echo "POSTGRES_PASSWORD=$PASSWORD"
    echo "TURBO_RUNTIME_DATABASE_URL=postgres://turbo_runtime:$PASSWORD@postgres:5432/turbo_runtime"
    echo "TURBO_RUNTIME_REDIS_URL=redis://redis:6379/"
    echo "TURBO_RUNTIME_BIND=0.0.0.0:8091"
    echo "TURBO_RUNTIME_ID=vm-runtime-1"
    echo "TURBO_RUNTIME_WEBSOCKET_MODE=clustered-single-active"
    echo "TURBO_RUNTIME_WEBSOCKET_OWNER_TTL_MS=15000"
    echo "TURBO_RUNTIME_PORT={runtime_port_q}"
  }} | sudo tee "$REMOTE_DIR/.env" >/dev/null
fi
upsert_env() {{
  KEY="$1"
  VALUE="$2"
  TMP="$(mktemp)"
  sudo awk -F= -v key="$KEY" '$1 != key {{ print }}' "$REMOTE_DIR/.env" > "$TMP"
  printf '%s=%s\\n' "$KEY" "$VALUE" >> "$TMP"
  sudo install -m 600 "$TMP" "$REMOTE_DIR/.env"
  rm -f "$TMP"
}}
{optional_runtime_env_script}
cd "$RELEASE_DIR"
sudo env TURBO_IMAGE={image_q} TURBO_RUNTIME_PORT={runtime_port_q} {profiles}docker compose --env-file "$REMOTE_DIR/.env" -f backend/infra/vm/docker-compose.yml up -d --build {services}
sudo docker compose --env-file "$REMOTE_DIR/.env" -f backend/infra/vm/docker-compose.yml ps
curl -fsS "http://127.0.0.1:{runtime_port}/s/turbo/v1/health" >/dev/null
"""


def gcloud_compute_scp_command(
    *, project: str, zone: str, instance: str, source: str, destination: str
) -> list[str]:
    return [
        "gcloud",
        "compute",
        "scp",
        source,
        destination,
        "--project",
        project,
        "--zone",
        zone,
    ]


def gcloud_compute_ssh_command(
    *, project: str, zone: str, instance: str, remote_script: str
) -> list[str]:
    return [
        "gcloud",
        "compute",
        "ssh",
        instance,
        "--project",
        project,
        "--zone",
        zone,
        "--command",
        remote_script,
    ]


def tool_preflight() -> list[dict[str, Any]]:
    return [
        {"name": "gcloud-cli", "ok": shutil.which("gcloud") is not None, "path": shutil.which("gcloud")},
        {"name": "docker-cli", "ok": shutil.which("docker") is not None, "path": shutil.which("docker")},
    ]


def run_step(
    name: str,
    command: list[str],
    *,
    dry_run: bool,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if dry_run:
        result = {"name": name, "ok": True, "dryRun": True, "command": command}
        if extra:
            result.update(extra)
        return result
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    result = {
        "name": name,
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "command": command,
        "stdout": completed.stdout.strip()[-4000:],
        "stderr": completed.stderr.strip()[-4000:],
    }
    if extra:
        result.update(extra)
    return result


def gcloud_project() -> str:
    if not shutil.which("gcloud"):
        return ""
    completed = subprocess.run(
        ["gcloud", "config", "get-value", "project"],
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.stdout.strip() if completed.returncode == 0 else ""


def git_short_sha() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode == 0 and completed.stdout.strip():
        return completed.stdout.strip()
    return datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
