import os
import json
import unittest
import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gce_vm_self_hosted_deploy


class GCEVMSelfHostedDeployTests(unittest.TestCase):
    def test_remote_deploy_script_keeps_relay_opt_in(self):
        script = gce_vm_self_hosted_deploy.build_remote_deploy_script(
            remote_dir="/opt/turbo-self-hosted",
            remote_archive="/tmp/release.tar.gz",
            release_name="release-a",
            image="turbo-self-hosted:abc123",
            runtime_port="8091",
            build_on_vm=False,
        )

        self.assertIn("docker compose", script)
        self.assertIn("pull postgres redis runtime", script)
        self.assertIn("up -d --no-build postgres redis runtime", script)
        self.assertNotIn("up -d --build", script)
        self.assertNotIn("COMPOSE_PROFILES=relay", script)
        self.assertNotIn("runtime relay", script)

    def test_include_relay_fails_before_deploy_steps(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "deploy.json"
            with mock.patch.object(
                sys,
                "argv",
                [
                    "gce_vm_self_hosted_deploy.py",
                    "--project",
                    "project-a",
                    "--include-relay",
                    "--dry-run",
                    "--output",
                    str(output),
                ],
            ):
                exit_code = gce_vm_self_hosted_deploy.main()

            summary = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(exit_code, 1)
        self.assertEqual(summary["status"], "fail")
        self.assertIn("relay", summary["services"])
        self.assertIn(
            "relay-profile-unsupported",
            [step["name"] for step in summary["steps"]],
        )
        self.assertNotIn("docker-build-push-image", [step["name"] for step in summary["steps"]])

    def test_remote_deploy_script_can_build_on_vm_as_explicit_fallback(self):
        script = gce_vm_self_hosted_deploy.build_remote_deploy_script(
            remote_dir="/opt/turbo-self-hosted",
            remote_archive="/tmp/release.tar.gz",
            release_name="release-a",
            image="turbo-self-hosted:abc123",
            runtime_port="8091",
            build_on_vm=True,
        )

        self.assertIn("up -d --build postgres redis runtime", script)
        self.assertNotIn("up -d --no-build", script)

    def test_registry_image_defaults_to_artifact_registry(self):
        image = gce_vm_self_hosted_deploy.registry_image(
            project="project-a",
            location="europe-west6",
            repository="turbo",
            tag="abc123",
        )

        self.assertEqual(
            image,
            "europe-west6-docker.pkg.dev/project-a/turbo/turbo-self-hosted:abc123",
        )
        self.assertEqual(
            gce_vm_self_hosted_deploy.registry_host_from_image(image),
            "europe-west6-docker.pkg.dev",
        )

    def test_registry_cache_image_replaces_runtime_tag(self):
        cache = gce_vm_self_hosted_deploy.registry_cache_image(
            "europe-west6-docker.pkg.dev/project-a/turbo/turbo-self-hosted:abc123"
        )

        self.assertEqual(
            cache,
            "europe-west6-docker.pkg.dev/project-a/turbo/turbo-self-hosted:buildcache",
        )

    def test_docker_build_push_uses_registry_cache(self):
        command = gce_vm_self_hosted_deploy.docker_build_push_command(
            "europe-west6-docker.pkg.dev/project-a/turbo/turbo-self-hosted:abc123",
            "europe-west6-docker.pkg.dev/project-a/turbo/turbo-self-hosted:buildcache",
        )

        self.assertEqual(command[:3], ["docker", "buildx", "build"])
        self.assertIn("--push", command)
        self.assertIn("--platform", command)
        self.assertIn("linux/amd64", command)
        self.assertIn("--cache-from", command)
        self.assertIn("--cache-to", command)
        self.assertIn(
            "type=registry,ref=europe-west6-docker.pkg.dev/project-a/turbo/turbo-self-hosted:buildcache",
            command,
        )
        self.assertIn(
            "type=registry,ref=europe-west6-docker.pkg.dev/project-a/turbo/turbo-self-hosted:buildcache,mode=max",
            command,
        )

    def test_dirty_worktree_blocks_live_deploy_by_default(self):
        step = gce_vm_self_hosted_deploy.git_worktree_guard_step(
            {"shortSha": "abc123", "dirty": True, "dirtyPaths": ["backend/runtime/src/lib.rs"]},
            allow_dirty=False,
            dry_run=False,
        )

        self.assertFalse(step["ok"])
        self.assertIn("clean git worktree", step["reason"])

    def test_dirty_worktree_dry_run_reports_live_block_without_failing_plan(self):
        step = gce_vm_self_hosted_deploy.git_worktree_guard_step(
            {"shortSha": "abc123", "dirty": True, "dirtyPaths": ["backend/runtime/src/lib.rs"]},
            allow_dirty=False,
            dry_run=True,
        )

        self.assertTrue(step["ok"])
        self.assertTrue(step["wouldBlockLiveDeploy"])

    def test_dirty_worktree_can_be_explicitly_allowed(self):
        step = gce_vm_self_hosted_deploy.git_worktree_guard_step(
            {"shortSha": "abc123", "dirty": True, "dirtyPaths": ["backend/runtime/src/lib.rs"]},
            allow_dirty=True,
            dry_run=False,
        )

        self.assertTrue(step["ok"])

    def test_scp_command_targets_compute_instance(self):
        command = gce_vm_self_hosted_deploy.gcloud_compute_scp_command(
            project="project-a",
            zone="europe-west6-a",
            instance="turbo-relay-1",
            source="/tmp/release.tar.gz",
            destination="turbo-relay-1:/tmp/release.tar.gz",
        )

        self.assertEqual(command[:3], ["gcloud", "compute", "scp"])
        self.assertIn("--project", command)
        self.assertIn("project-a", command)
        self.assertIn("--zone", command)
        self.assertIn("europe-west6-a", command)

    def test_release_archive_excludes_local_secret_files(self):
        repo_root = Path("/repo")

        self.assertTrue(
            gce_vm_self_hosted_deploy.should_exclude(
                repo_root / ".envrc",
                repo_root,
                repo_root / "backend/infra/vm/build/release.tar.gz",
            )
        )
        self.assertTrue(
            gce_vm_self_hosted_deploy.should_exclude(
                repo_root / ".git/config",
                repo_root,
                repo_root / "backend/infra/vm/build/release.tar.gz",
            )
        )
        self.assertFalse(
            gce_vm_self_hosted_deploy.should_exclude(
                repo_root / "backend/infra/vm/build/kernel/request-talk-turn.uc",
                repo_root,
                repo_root / "backend/infra/vm/build/release.tar.gz",
            )
        )

    def test_artifact_redaction_hides_secret_environment_values(self):
        with mock.patch.dict(os.environ, {"TURBO_APNS_WORKER_SECRET": "secret-value-123"}, clear=False):
            redacted = gce_vm_self_hosted_deploy.redact_for_artifact(
                {
                    "command": [
                        "gcloud",
                        "compute",
                        "ssh",
                        "--command",
                        "upsert_env TURBO_APNS_WORKER_SECRET secret-value-123",
                    ],
                    "remoteScript": "upsert_env TURBO_APNS_WORKER_SECRET secret-value-123",
                    "workerSecret": "secret-value-123",
                }
            )

        self.assertNotIn("secret-value-123", str(redacted))
        self.assertIn("<redacted>", str(redacted))


if __name__ == "__main__":
    unittest.main()
