import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import compile_unison_kernel_artifacts


class CompileUnisonKernelArtifactsTests(unittest.TestCase):
    def test_dry_run_compile_uses_filename_without_path_for_ucm(self):
        step = compile_unison_kernel_artifacts.compile_artifact(
            repo_root=Path("/repo"),
            output_dir=Path("/repo/backend/infra/vm/build/kernel"),
            project="bb/main",
            name="request-talk-turn",
            entrypoint=".beepbeep.worker.requestTalkTurn.printDecisionJson",
            dry_run=True,
        )

        self.assertTrue(step["ok"])
        self.assertIn("compile .beepbeep.worker.requestTalkTurn.printDecisionJson", step["stdin"])
        self.assertIn("turbo-kernel-request-talk-turn", step["stdin"])
        self.assertEqual(step["output"], "/repo/backend/infra/vm/build/kernel/request-talk-turn.uc")


if __name__ == "__main__":
    unittest.main()
