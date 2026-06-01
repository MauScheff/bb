import unittest
import sys
from pathlib import Path

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
            include_relay=False,
        )

        self.assertIn("docker compose", script)
        self.assertIn("up -d --build postgres redis runtime", script)
        self.assertNotIn("COMPOSE_PROFILES=relay", script)
        self.assertNotIn("runtime relay", script)

    def test_remote_deploy_script_can_include_relay_profile(self):
        script = gce_vm_self_hosted_deploy.build_remote_deploy_script(
            remote_dir="/opt/turbo-self-hosted",
            remote_archive="/tmp/release.tar.gz",
            release_name="release-a",
            image="turbo-self-hosted:abc123",
            runtime_port="8091",
            include_relay=True,
        )

        self.assertIn("COMPOSE_PROFILES=relay", script)
        self.assertIn("up -d --build postgres redis runtime relay", script)

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


if __name__ == "__main__":
    unittest.main()
