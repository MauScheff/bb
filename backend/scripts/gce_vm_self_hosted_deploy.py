#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_ZONE = "europe-west6-a"
DEFAULT_INSTANCE = "turbo-self-hosted-1"
DEFAULT_REMOTE_DIR = "/opt/turbo-self-hosted"
DEFAULT_OUTPUT = "/tmp/turbo-gce-self-hosted-deploy.json"
DEFAULT_REGISTRY_LOCATION = "europe-west6"
DEFAULT_REGISTRY_REPOSITORY = "turbo"
DEFAULT_IMAGE_PLATFORM = "linux/amd64"
IMAGE_NAME = "turbo-self-hosted"
SENSITIVE_ENV_NAME_PARTS = ("PASSWORD", "PRIVATE_KEY", "SECRET", "TOKEN")
SOURCE_RELEASE_ROOTS = [
    "Cargo.toml",
    "Cargo.lock",
    "backend/runtime",
    "backend/relay-protocol",
    "backend/infra/self-hosted",
    "backend/infra/vm/Dockerfile",
    "backend/infra/vm/docker-compose.yml",
    "backend/infra/vm/build/kernel",
]
REGISTRY_RELEASE_ROOTS = [
    "backend/infra/self-hosted/sql",
    "backend/infra/vm/Dockerfile",
    "backend/infra/vm/docker-compose.yml",
]
DEPLOY_GIT_PATHS = [
    "Cargo.toml",
    "Cargo.lock",
    "backend/runtime",
    "backend/relay-protocol",
    "backend/infra/self-hosted",
    "backend/infra/vm",
    "backend/scripts/gce_vm_self_hosted_deploy.py",
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
    parser.add_argument("--image", default=os.environ.get("TURBO_GCE_IMAGE", ""))
    parser.add_argument(
        "--registry-location",
        default=os.environ.get("TURBO_GCE_REGISTRY_LOCATION", DEFAULT_REGISTRY_LOCATION),
    )
    parser.add_argument(
        "--registry-repository",
        default=os.environ.get("TURBO_GCE_REGISTRY_REPOSITORY", DEFAULT_REGISTRY_REPOSITORY),
    )
    parser.add_argument("--runtime-port", default=os.environ.get("TURBO_RUNTIME_PORT", "8091"))
    parser.add_argument(
        "--image-platform",
        default=os.environ.get("TURBO_GCE_IMAGE_PLATFORM", DEFAULT_IMAGE_PLATFORM),
        help="Container platform to build for the VM. Defaults to linux/amd64.",
    )
    parser.add_argument(
        "--build-cache-image",
        default=os.environ.get("TURBO_GCE_BUILD_CACHE_IMAGE", ""),
        help="Registry ref for BuildKit cache export/import. Defaults beside the runtime image.",
    )
    parser.add_argument(
        "--disable-build-cache",
        action="store_true",
        default=os.environ.get("TURBO_GCE_DISABLE_BUILD_CACHE", "") in {"1", "true", "TRUE", "yes", "YES"},
        help="Build without registry-backed BuildKit cache import/export.",
    )
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument("--include-relay", action="store_true")
    parser.add_argument("--skip-kernel-compile", action="store_true")
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        default=os.environ.get("TURBO_GCE_ALLOW_DIRTY", "") in {"1", "true", "TRUE", "yes", "YES"},
        help="Allow live deploys from a dirty git worktree. Auto-suffixes the image tag unless --image-tag is set.",
    )
    parser.add_argument(
        "--skip-image-build-push",
        action="store_true",
        help="Deploy the selected registry image without building or pushing it first.",
    )
    parser.add_argument(
        "--build-on-vm",
        action="store_true",
        help="Legacy fallback: copy source to the VM and run docker compose up --build there.",
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    docker_config_dir = tempfile.mkdtemp(prefix="turbo-gce-docker-config-")
    try:
        return run_deploy(args, docker_config_dir)
    finally:
        shutil.rmtree(docker_config_dir, ignore_errors=True)


def run_deploy(args: argparse.Namespace, docker_config_dir: str) -> int:
    repo_root = Path.cwd()
    project = args.project or gcloud_project()
    source_state = git_worktree_state(DEPLOY_GIT_PATHS)
    image_tag = args.image_tag or source_state.get("shortSha") or git_short_sha()
    if source_state.get("dirty") and args.allow_dirty and not args.image_tag:
        image_tag = f"{image_tag}-dirty-{utc_tag_timestamp()}"
    release_name = f"turbo-self-hosted-{image_tag}"
    release_archive = repo_root / "backend" / "infra" / "vm" / "build" / f"{release_name}.tar.gz"
    remote_archive = f"/tmp/{release_name}.tar.gz"
    image = args.image or registry_image(
        project=project,
        location=args.registry_location,
        repository=args.registry_repository,
        tag=image_tag,
    )
    if args.build_on_vm and not args.image:
        image = f"{IMAGE_NAME}:{image_tag}"
    build_cache_image = ""
    if not args.build_on_vm and not args.disable_build_cache:
        build_cache_image = args.build_cache_image or registry_cache_image(image)
    steps: list[dict[str, Any]] = []

    required = {
        "project": project,
        "zone": args.zone,
        "instance": args.instance,
        "remoteDir": args.remote_dir,
        "image": image,
    }
    if not args.build_on_vm and not args.image:
        required["registryLocation"] = args.registry_location
        required["registryRepository"] = args.registry_repository
    steps.extend(tool_preflight())
    steps.append(git_worktree_guard_step(source_state, allow_dirty=args.allow_dirty, dry_run=args.dry_run))
    steps.append({"name": "deploy-config", "ok": all(required.values()), "values": required})
    if steps[-2].get("ok") is not True:
        return finish_deploy(
            args=args,
            steps=steps,
            release_name=release_name,
            image=image,
            build_cache_image=build_cache_image,
            project=project,
            source_state=source_state,
        )
    if args.include_relay:
        steps.append(
            {
                "name": "relay-profile-unsupported",
                "ok": False,
                "reason": "The self-hosted runtime image no longer builds or carries the standalone relay binary. Deploy relay with its dedicated VM/image path.",
            }
        )
        summary = deploy_summary(
            args=args,
            ok=False,
            steps=steps,
            release_name=release_name,
            image=image,
            build_cache_image=build_cache_image,
            project=project,
            source_state=source_state,
        )
        write_summary(summary, Path(args.output))
        return 1

    if not args.skip_kernel_compile:
        steps.append(run_step("kernel-compile", kernel_compile_command(), dry_run=args.dry_run))
        if steps[-1].get("ok") is not True:
            return finish_deploy(
                args=args,
                steps=steps,
                release_name=release_name,
                image=image,
                build_cache_image=build_cache_image,
                project=project,
                source_state=source_state,
            )

    if not args.build_on_vm and not args.skip_image_build_push:
        steps.append(
            run_step(
                "registry-auth-local",
                docker_registry_auth_command(args.registry_location, docker_config_dir),
                dry_run=args.dry_run,
            )
        )
        if steps[-1].get("ok") is not True:
            return finish_deploy(
                args=args,
                steps=steps,
                release_name=release_name,
                image=image,
                build_cache_image=build_cache_image,
                project=project,
                source_state=source_state,
            )
        steps.append(
            run_step(
                "docker-build-push-image",
                docker_build_push_command(
                    image,
                    build_cache_image,
                    docker_config_dir,
                    platform=args.image_platform,
                ),
                dry_run=args.dry_run,
            )
        )
        if steps[-1].get("ok") is not True:
            return finish_deploy(
                args=args,
                steps=steps,
                release_name=release_name,
                image=image,
                build_cache_image=build_cache_image,
                project=project,
                source_state=source_state,
            )

    steps.append(
        create_release_archive(
            repo_root=repo_root,
            archive_path=release_archive,
            release_roots=SOURCE_RELEASE_ROOTS if args.build_on_vm else REGISTRY_RELEASE_ROOTS,
            dry_run=args.dry_run,
        )
    )
    if steps[-1].get("ok") is not True:
        return finish_deploy(
            args=args,
            steps=steps,
            release_name=release_name,
            image=image,
               build_cache_image=build_cache_image,
               project=project,
               source_state=source_state,
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
        build_on_vm=args.build_on_vm,
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

    return finish_deploy(
        args=args,
        steps=steps,
        release_name=release_name,
        image=image,
        build_cache_image=build_cache_image,
        project=project,
        source_state=source_state,
    )


def finish_deploy(
    *,
    args: argparse.Namespace,
    steps: list[dict[str, Any]],
    release_name: str,
    image: str,
    build_cache_image: str,
    project: str,
    source_state: dict[str, Any],
) -> int:
    ok = all(step.get("ok") is True for step in steps)
    summary = deploy_summary(
        args=args,
        ok=ok,
        steps=steps,
        release_name=release_name,
        image=image,
        build_cache_image=build_cache_image,
        project=project,
        source_state=source_state,
    )
    write_summary(summary, Path(args.output))
    return 0 if ok else 1


def deploy_summary(
    *,
    args: argparse.Namespace,
    ok: bool,
    steps: list[dict[str, Any]],
    release_name: str,
    image: str,
    build_cache_image: str,
    project: str,
    source_state: dict[str, Any],
) -> dict[str, Any]:
    return {
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
        "source": {
            "shortSha": source_state.get("shortSha"),
            "dirty": source_state.get("dirty"),
            "dirtyPaths": source_state.get("dirtyPaths", []),
            "pathScope": source_state.get("pathScope", []),
            "allowDirty": args.allow_dirty,
        },
        "deployMode": "build-on-vm" if args.build_on_vm else "registry",
        "registry": None
        if args.build_on_vm
        else {
            "location": args.registry_location,
            "repository": args.registry_repository,
            "host": registry_host_from_image(image),
            "imagePlatform": args.image_platform,
            "imageBuildPushSkipped": args.skip_image_build_push,
            "buildCacheImage": build_cache_image or None,
            "buildCacheDisabled": args.disable_build_cache,
        },
        "includeRelay": args.include_relay,
        "kernelPackaging": {
            "mode": "compiled-uc-artifacts",
            "productionRecommended": True,
            "note": "UCM is used to execute sealed .uc artifacts; no live Unison codebase is packaged into the VM image.",
        },
        "services": ["postgres", "redis", "runtime"] + (["relay"] if args.include_relay else []),
        "steps": steps,
    }


def write_summary(summary: dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"gce self-hosted deploy status: {summary['status']}")
    print(f"gce self-hosted deploy artifact: {output}")


def kernel_compile_command() -> list[str]:
    return [
        "python3",
        "backend/scripts/compile_unison_kernel_artifacts.py",
        "--output-dir",
        "backend/infra/vm/build/kernel",
        "--summary",
        "/tmp/turbo-kernel-compile.json",
    ]


def registry_image(*, project: str, location: str, repository: str, tag: str) -> str:
    return f"{location}-docker.pkg.dev/{project}/{repository}/{IMAGE_NAME}:{tag}"


def registry_cache_image(image: str) -> str:
    name = image.rsplit("/", 1)[-1]
    if ":" not in name:
        return f"{image}:buildcache"
    return f"{image.rsplit(':', 1)[0]}:buildcache"


def docker_registry_auth_command(location: str, docker_config_dir: str = "") -> list[str]:
    host = f"{location}-docker.pkg.dev"
    config_prefix = f"DOCKER_CONFIG={shlex.quote(docker_config_dir)} " if docker_config_dir else ""
    prepare_config = "true"
    if docker_config_dir:
        docker_config_dir_q = shlex.quote(docker_config_dir)
        cli_plugins_q = shlex.quote(f"{docker_config_dir}/cli-plugins")
        prepare_config = (
            f"mkdir -p {docker_config_dir_q} && "
            f"if [ -d \"$HOME/.docker/cli-plugins\" ] && [ ! -e {cli_plugins_q} ]; "
            f"then ln -s \"$HOME/.docker/cli-plugins\" {cli_plugins_q}; fi"
        )
    return [
        "sh",
        "-c",
        (
            f"{prepare_config} && "
            f"gcloud auth print-access-token | "
            f"{config_prefix}docker login -u oauth2accesstoken --password-stdin https://{host}"
        ),
    ]


def docker_build_push_command(
    image: str,
    build_cache_image: str = "",
    docker_config_dir: str = "",
    *,
    platform: str = DEFAULT_IMAGE_PLATFORM,
    dockerfile: str = "backend/infra/vm/Dockerfile",
) -> list[str]:
    command = [
        *(
            ["env", f"DOCKER_CONFIG={docker_config_dir}"]
            if docker_config_dir
            else []
        ),
        "docker",
        "buildx",
        "build",
        "-f",
        dockerfile,
        "-t",
        image,
    ]
    if platform:
        command.extend(["--platform", platform])
    command.append("--push")
    if build_cache_image:
        command.extend(
            [
                "--cache-from",
                f"type=registry,ref={build_cache_image}",
                "--cache-to",
                f"type=registry,ref={build_cache_image},mode=max",
            ]
        )
    command.append(".")
    return command


def create_release_archive(
    *,
    repo_root: Path,
    archive_path: Path,
    release_roots: list[str],
    dry_run: bool,
) -> dict[str, Any]:
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    if dry_run:
        return {
            "name": "create-release-archive",
            "ok": True,
            "dryRun": True,
            "archive": str(archive_path),
            "releaseRoots": release_roots,
        }
    with tarfile.open(archive_path, "w:gz") as archive:
        for path in archive_paths(repo_root, archive_path, release_roots):
            if should_exclude(path, repo_root, archive_path):
                continue
            archive.add(path, arcname=path.relative_to(repo_root))
    return {
        "name": "create-release-archive",
        "ok": True,
        "archive": str(archive_path),
        "bytes": archive_path.stat().st_size,
        "releaseRoots": release_roots,
    }


def archive_paths(repo_root: Path, archive_path: Path, release_roots: list[str]) -> list[Path]:
    paths: list[Path] = []
    for release_root in release_roots:
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
    build_on_vm: bool,
) -> str:
    remote_dir_q = shlex.quote(remote_dir)
    remote_archive_q = shlex.quote(remote_archive)
    release_name_q = shlex.quote(release_name)
    image_q = shlex.quote(image)
    runtime_port_q = shlex.quote(runtime_port)
    services = "postgres redis runtime"
    compose_prefix = (
        f"sudo env TURBO_IMAGE={image_q} TURBO_RUNTIME_PORT={runtime_port_q} "
        'docker compose --env-file "$REMOTE_DIR/.env" -f backend/infra/vm/docker-compose.yml'
    )
    registry_login_script = remote_registry_login_script(image) if not build_on_vm else ""
    compose_step_script = (
        f"{compose_prefix} up -d --build postgres redis\napply_runtime_schema\n{compose_prefix} up -d --build runtime"
        if build_on_vm
        else f"{compose_prefix} pull {services}\n{compose_prefix} up -d --no-build postgres redis\napply_runtime_schema\n{compose_prefix} up -d --no-build runtime"
    )
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
if ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl openssl
fi
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
{registry_login_script}
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
wait_for_postgres() {{
  ATTEMPTS=0
  until sudo docker compose --env-file "$REMOTE_DIR/.env" -f backend/infra/vm/docker-compose.yml exec -T postgres sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge 60 ]; then
      echo "postgres did not become ready for runtime schema apply" >&2
      return 1
    fi
    sleep 1
  done
}}
apply_runtime_schema() {{
  if [ ! -f backend/infra/self-hosted/sql/001_runtime_schema.sql ]; then
    echo "runtime schema file missing from release archive" >&2
    return 1
  fi
  wait_for_postgres
  sudo docker compose --env-file "$REMOTE_DIR/.env" -f backend/infra/vm/docker-compose.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < backend/infra/self-hosted/sql/001_runtime_schema.sql
}}
{compose_step_script}
sudo docker compose --env-file "$REMOTE_DIR/.env" -f backend/infra/vm/docker-compose.yml ps
curl -fsS "http://127.0.0.1:{runtime_port}/s/turbo/v1/health" >/dev/null
"""


def registry_host_from_image(image: str) -> str | None:
    first = image.split("/", 1)[0]
    if "." in first or ":" in first or first == "localhost":
        return first
    return None


def remote_registry_login_script(image: str) -> str:
    host = registry_host_from_image(image)
    if host is None or not host.endswith(".pkg.dev"):
        return ""
    host_q = shlex.quote(host)
    return f"""
REGISTRY_HOST={host_q}
TOKEN="$(curl -fsS -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')"
if [ -z "$TOKEN" ]; then
  echo "failed to obtain Compute Engine metadata access token for Artifact Registry pull" >&2
  exit 1
fi
printf '%s' "$TOKEN" | sudo docker login -u oauth2accesstoken --password-stdin "https://$REGISTRY_HOST"
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


def git_worktree_state(paths: list[str] | None = None) -> dict[str, Any]:
    short_sha = git_short_sha()
    command = ["git", "status", "--porcelain"]
    if paths:
        command.extend(["--", *paths])
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return {
            "shortSha": short_sha,
            "dirty": True,
            "dirtyPaths": [],
            "pathScope": paths or [],
            "statusAvailable": False,
            "reason": completed.stderr.strip()[-1000:] or "git status failed",
        }
    dirty_paths = [
        line[3:]
        for line in completed.stdout.splitlines()
        if len(line) >= 4
    ]
    return {
        "shortSha": short_sha,
        "dirty": bool(dirty_paths),
        "dirtyPaths": dirty_paths[:100],
        "pathScope": paths or [],
        "statusAvailable": True,
    }


def git_worktree_guard_step(
    source_state: dict[str, Any],
    *,
    allow_dirty: bool,
    dry_run: bool,
) -> dict[str, Any]:
    dirty = bool(source_state.get("dirty"))
    ok = (not dirty) or allow_dirty or dry_run
    step = {
        "name": "git-worktree-clean",
        "ok": ok,
        "shortSha": source_state.get("shortSha"),
        "dirty": dirty,
        "allowDirty": allow_dirty,
        "dirtyPaths": source_state.get("dirtyPaths", []),
        "pathScope": source_state.get("pathScope", []),
    }
    if dirty and dry_run and not allow_dirty:
        step["wouldBlockLiveDeploy"] = True
    if dirty and not allow_dirty:
        step["reason"] = "live deploys require a clean git worktree or --allow-dirty"
    return step


def run_step(
    name: str,
    command: list[str],
    *,
    dry_run: bool,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if dry_run:
        result = {"name": name, "ok": True, "dryRun": True, "command": redact_for_artifact(command)}
        if extra:
            result.update(redact_for_artifact(extra))
        return result
    started = time.monotonic()
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    duration_seconds = round(time.monotonic() - started, 3)
    result = {
        "name": name,
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "command": redact_for_artifact(command),
        "durationSeconds": duration_seconds,
        "stdout": completed.stdout.strip()[-4000:],
        "stderr": completed.stderr.strip()[-4000:],
    }
    if extra:
        result.update(redact_for_artifact(extra))
    return result


def redact_for_artifact(value: Any) -> Any:
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        return [redact_for_artifact(item) for item in value]
    if isinstance(value, dict):
        redacted: dict[str, Any] = {}
        for key, item in value.items():
            if is_sensitive_name(str(key)):
                redacted[key] = "<redacted>"
            else:
                redacted[key] = redact_for_artifact(item)
        return redacted
    return value


def redact_text(text: str) -> str:
    redacted = text
    for secret in redaction_values():
        redacted = redacted.replace(secret, "<redacted>")
    return redacted


def redaction_values() -> list[str]:
    values = [
        value
        for key, value in os.environ.items()
        if is_sensitive_name(key) and len(value) >= 8
    ]
    return sorted(set(values), key=len, reverse=True)


def is_sensitive_name(name: str) -> bool:
    upper = name.upper()
    return any(part in upper for part in SENSITIVE_ENV_NAME_PARTS)


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


def utc_tag_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")


if __name__ == "__main__":
    raise SystemExit(main())
