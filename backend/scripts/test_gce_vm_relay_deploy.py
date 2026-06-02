import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gce_vm_relay_deploy


class GCERelayDeployTests(unittest.TestCase):
    def test_registry_image_defaults_to_relay_image(self):
        image = gce_vm_relay_deploy.registry_image(
            project="project-a",
            location="europe-west6",
            repository="turbo",
            tag="abc123",
        )

        self.assertEqual(
            image,
            "europe-west6-docker.pkg.dev/project-a/turbo/beepbeep-relay:abc123",
        )

    def test_remote_script_refuses_active_systemd_service_by_default(self):
        script = gce_vm_relay_deploy.build_remote_relay_script(
            image="relay:abc123",
            remote_dir="/opt/beepbeep-relay",
            replace_systemd_service=False,
        )

        self.assertIn("systemctl is-active --quiet turbo-relay", script)
        self.assertIn("--replace-systemd-service", script)
        self.assertNotIn("systemctl disable turbo-relay || true", script)

    def test_remote_script_can_replace_systemd_service(self):
        script = gce_vm_relay_deploy.build_remote_relay_script(
            image="relay:abc123",
            remote_dir="/opt/beepbeep-relay",
            replace_systemd_service=True,
        )

        self.assertIn("systemctl stop turbo-relay || true", script)
        self.assertIn("docker run -d --name beepbeep-relay", script)

    def test_relay_build_uses_relay_dockerfile(self):
        command = gce_vm_relay_deploy.vm_deploy.docker_build_push_command(
            "europe-west6-docker.pkg.dev/project-a/turbo/beepbeep-relay:abc123",
            "europe-west6-docker.pkg.dev/project-a/turbo/beepbeep-relay:buildcache",
            platform="linux/amd64",
            dockerfile=gce_vm_relay_deploy.DOCKERFILE,
        )

        self.assertIn("backend/infra/relay/Dockerfile", command)
        self.assertIn("--cache-to", command)


if __name__ == "__main__":
    unittest.main()
