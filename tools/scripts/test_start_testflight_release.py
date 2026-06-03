import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import start_testflight_release


class FakeAppStoreConnect:
    def __init__(self, workflow_url: str):
        self.workflow_url = workflow_url

    def request(self, method: str, path: str):
        self.assert_request(method, path)
        return {
            "data": {
                "attributes": {
                    "httpCloneUrl": self.workflow_url,
                }
            }
        }

    def assert_request(self, method: str, path: str) -> None:
        if method != "GET":
            raise AssertionError(f"unexpected method {method}")
        if path != "/ciWorkflows/workflow-1/repository":
            raise AssertionError(f"unexpected path {path}")


class StartTestFlightReleaseTests(unittest.TestCase):
    def test_normalized_git_url_matches_https_and_ssh_github_forms(self):
        self.assertEqual(
            start_testflight_release.normalized_git_url("git@github.com:MauScheff/bb.git"),
            "https://github.com/MauScheff/bb.git",
        )
        self.assertEqual(
            start_testflight_release.normalized_git_url("ssh://git@github.com/MauScheff/bb"),
            "https://github.com/MauScheff/bb.git",
        )

    def test_workflow_repository_mismatch_fails_before_build_start(self):
        api = FakeAppStoreConnect("https://github.com/MauScheff/Turbo.git")
        with self.assertRaisesRegex(
            start_testflight_release.ReleaseError,
            "workflow repository does not match",
        ):
            start_testflight_release.require_workflow_repository_matches_origin(
                api,
                "workflow-1",
                "https://github.com/MauScheff/bb.git",
            )

    def test_workflow_repository_match_passes(self):
        api = FakeAppStoreConnect("git@github.com:MauScheff/bb.git")
        start_testflight_release.require_workflow_repository_matches_origin(
            api,
            "workflow-1",
            "https://github.com/MauScheff/bb",
        )


if __name__ == "__main__":
    unittest.main()
