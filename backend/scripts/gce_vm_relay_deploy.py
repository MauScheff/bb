#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shutil
import tempfile
from pathlib import Path
from typing import Any

import gce_vm_self_hosted_deploy as vm_deploy


DEFAULT_ZONE = "europe-west6-a"
DEFAULT_INSTANCE = "turbo-relay-1"
DEFAULT_OUTPUT = "/tmp/bb-gce-relay-deploy.json"
DEFAULT_REMOTE_DIR = "/opt/beepbeep-relay"
DEFAULT_REGISTRY_LOCATION = "europe-west6"
DEFAULT_REGISTRY_REPOSITORY = "turbo"
DEFAULT_IMAGE_PLATFORM = "linux/amd64"
IMAGE_NAME = "beepbeep-relay"
DOCKERFILE = "backend/infra/relay/Dockerfile"
DEPLOY_GIT_PATHS = [
    "Cargo.toml",
    "Cargo.lock",
    "backend/relay",
    "backend/relay-protocol",
    "backend/infra/relay",
    "backend/scripts/gce_vm_relay_deploy.py",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Deploy the BeepBeep relay to its dedicated VM.")
    parser.add_argument("--project", default=os.environ.get("TURBO_GCE_PROJECT", ""))
    parser.add_argument("--zone", default=os.environ.get("TURBO_RELAY_GCE_ZONE", DEFAULT_ZONE))
    parser.add_argument("--instance", default=os.environ.get("TURBO_RELAY_GCE_INSTANCE", DEFAULT_INSTANCE))
    parser.add_argument("--remote-dir", default=os.environ.get("TURBO_RELAY_GCE_REMOTE_DIR", DEFAULT_REMOTE_DIR))
    parser.add_argument("--image-tag", default=os.environ.get("TURBO_RELAY_GCE_IMAGE_TAG", ""))
    parser.add_argument("--image", default=os.environ.get("TURBO_RELAY_GCE_IMAGE", ""))
    parser.add_argument(
        "--registry-location",
        default=os.environ.get("TURBO_GCE_REGISTRY_LOCATION", DEFAULT_REGISTRY_LOCATION),
    )
    parser.add_argument(
        "--registry-repository",
        default=os.environ.get("TURBO_GCE_REGISTRY_REPOSITORY", DEFAULT_REGISTRY_REPOSITORY),
    )
    parser.add_argument(
        "--image-platform",
        default=os.environ.get("TURBO_GCE_IMAGE_PLATFORM", DEFAULT_IMAGE_PLATFORM),
    )
    parser.add_argument(
        "--build-cache-image",
        default=os.environ.get("TURBO_RELAY_GCE_BUILD_CACHE_IMAGE", ""),
    )
    parser.add_argument(
        "--disable-build-cache",
        action="store_true",
        default=os.environ.get("TURBO_GCE_DISABLE_BUILD_CACHE", "") in {"1", "true", "TRUE", "yes", "YES"},
    )
    parser.add_argument(
        "--skip-image-build-push",
        action="store_true",
        help="Deploy the selected registry image without building or pushing it first.",
    )
    parser.add_argument(
        "--replace-systemd-service",
        action="store_true",
        help="Stop and disable an active turbo-relay systemd service before starting the container.",
    )
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        default=os.environ.get("TURBO_GCE_ALLOW_DIRTY", "") in {"1", "true", "TRUE", "yes", "YES"},
    )
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    docker_config_dir = tempfile.mkdtemp(prefix="bb-gce-relay-docker-config-")
    try:
        return run_deploy(args, docker_config_dir)
    finally:
        shutil.rmtree(docker_config_dir, ignore_errors=True)


def run_deploy(args: argparse.Namespace, docker_config_dir: str) -> int:
    project = args.project or vm_deploy.gcloud_project()
    source_state = vm_deploy.git_worktree_state(DEPLOY_GIT_PATHS)
    image_tag = args.image_tag or source_state.get("shortSha") or vm_deploy.git_short_sha()
    if source_state.get("dirty") and args.allow_dirty and not args.image_tag:
        image_tag = f"{image_tag}-dirty-{vm_deploy.utc_tag_timestamp()}"
    image = args.image or registry_image(
        project=project,
        location=args.registry_location,
        repository=args.registry_repository,
        tag=image_tag,
    )
    build_cache_image = ""
    if not args.disable_build_cache:
        build_cache_image = args.build_cache_image or vm_deploy.registry_cache_image(image)
    steps: list[dict[str, Any]] = []
    steps.extend(vm_deploy.tool_preflight())
    steps.append(vm_deploy.git_worktree_guard_step(source_state, allow_dirty=args.allow_dirty, dry_run=args.dry_run))
    steps.append(
        {
            "name": "deploy-config",
            "ok": all([project, args.zone, args.instance, args.remote_dir, image]),
            "values": {
                "project": project,
                "zone": args.zone,
                "instance": args.instance,
                "remoteDir": args.remote_dir,
                "image": image,
            },
        }
    )
    if steps[-2].get("ok") is not True:
        return finish(args, steps, image, build_cache_image, source_state, project)

    if not args.skip_image_build_push:
        steps.append(
            vm_deploy.run_step(
                "registry-auth-local",
                vm_deploy.docker_registry_auth_command(args.registry_location, docker_config_dir),
                dry_run=args.dry_run,
            )
        )
        if steps[-1].get("ok") is not True:
            return finish(args, steps, image, build_cache_image, source_state, project)
        steps.append(
            vm_deploy.run_step(
                "docker-build-push-relay-image",
                vm_deploy.docker_build_push_command(
                    image,
                    build_cache_image,
                    docker_config_dir,
                    platform=args.image_platform,
                    dockerfile=DOCKERFILE,
                ),
                dry_run=args.dry_run,
            )
        )
        if steps[-1].get("ok") is not True:
            return finish(args, steps, image, build_cache_image, source_state, project)

    remote_script = build_remote_relay_script(
        image=image,
        remote_dir=args.remote_dir,
        replace_systemd_service=args.replace_systemd_service,
    )
    steps.append(
        vm_deploy.run_step(
            "remote-relay-up",
            vm_deploy.gcloud_compute_ssh_command(
                project=project,
                zone=args.zone,
                instance=args.instance,
                remote_script=remote_script,
            ),
            dry_run=args.dry_run,
            extra={"remoteScript": remote_script},
        )
    )
    return finish(args, steps, image, build_cache_image, source_state, project)


def registry_image(*, project: str, location: str, repository: str, tag: str) -> str:
    return f"{location}-docker.pkg.dev/{project}/{repository}/{IMAGE_NAME}:{tag}"


def build_remote_relay_script(*, image: str, remote_dir: str, replace_systemd_service: bool) -> str:
    image_q = vm_deploy.shlex.quote(image)
    remote_dir_q = vm_deploy.shlex.quote(remote_dir)
    registry_login_script = vm_deploy.remote_registry_login_script(image)
    replace_script = (
        "sudo systemctl stop turbo-relay || true\nsudo systemctl disable turbo-relay || true"
        if replace_systemd_service
        else """
if systemctl is-active --quiet turbo-relay; then
  echo "turbo-relay systemd service is active; rerun with --replace-systemd-service to replace it with the container path" >&2
  exit 1
fi
"""
    )
    return f"""set -euo pipefail
REMOTE_DIR={remote_dir_q}
if ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
fi
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
{registry_login_script}
{replace_script}
sudo mkdir -p "$REMOTE_DIR" /etc/turbo-relay
if [ ! -f /etc/turbo-relay/env ]; then
  sudo install -m 600 /dev/null /etc/turbo-relay/env
  {{
    echo "TURBO_RELAY_CERT_PEM=/etc/letsencrypt/live/relay.beepbeep.to/fullchain.pem"
    echo "TURBO_RELAY_KEY_PEM=/etc/letsencrypt/live/relay.beepbeep.to/privkey.pem"
    echo "TURBO_RELAY_SHARED_TOKEN="
    echo "TURBO_RELAY_QUIC_ADDR=0.0.0.0:443"
    echo "TURBO_RELAY_TCP_ADDR=0.0.0.0:443"
    echo "TURBO_RELAY_SESSION_TTL_SECONDS=180"
  }} | sudo tee /etc/turbo-relay/env >/dev/null
fi
sudo docker pull {image_q}
sudo docker rm -f beepbeep-relay >/dev/null 2>&1 || true
sudo docker run -d --name beepbeep-relay --restart unless-stopped \\
  --env-file /etc/turbo-relay/env \\
  -v /etc/letsencrypt:/etc/letsencrypt:ro \\
  -p 443:443/udp -p 443:443/tcp \\
  {image_q}
sudo docker ps --filter name=beepbeep-relay
"""


def finish(
    args: argparse.Namespace,
    steps: list[dict[str, Any]],
    image: str,
    build_cache_image: str,
    source_state: dict[str, Any],
    project: str,
) -> int:
    ok = all(step.get("ok") is True for step in steps)
    summary = {
        "schemaVersion": 1,
        "generatedAt": vm_deploy.utc_now(),
        "status": "pass" if ok else "fail",
        "ok": ok,
        "dryRun": args.dry_run,
        "project": project,
        "zone": args.zone,
        "instance": args.instance,
        "remoteDir": args.remote_dir,
        "image": image,
        "registry": {
            "location": args.registry_location,
            "repository": args.registry_repository,
            "host": vm_deploy.registry_host_from_image(image),
            "imagePlatform": args.image_platform,
            "imageBuildPushSkipped": args.skip_image_build_push,
            "buildCacheImage": build_cache_image or None,
            "buildCacheDisabled": args.disable_build_cache,
        },
        "source": {
            "shortSha": source_state.get("shortSha"),
            "dirty": source_state.get("dirty"),
            "dirtyPaths": source_state.get("dirtyPaths", []),
            "pathScope": source_state.get("pathScope", []),
            "allowDirty": args.allow_dirty,
        },
        "replaceSystemdService": args.replace_systemd_service,
        "steps": steps,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"gce relay deploy status: {summary['status']}")
    print(f"gce relay deploy artifact: {output}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
