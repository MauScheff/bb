import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import kernel_invocation_audit


class KernelInvocationAuditTests(unittest.TestCase):
    def test_extract_cases_accepts_wrapped_corpus(self):
        cases = kernel_invocation_audit.extract_cases({"corpus": {"cases": [{"id": "a"}]}})

        self.assertEqual(cases, [{"id": "a"}])

    def test_compiled_command_uses_run_compiled_artifact(self):
        command = kernel_invocation_audit.compiled_command(
            artifact=Path("/app/kernel/request-talk-turn.uc"),
            input_text="{}",
        )

        self.assertEqual(command[:4], ["direnv", "exec", ".", "ucm"])
        self.assertIn("run.compiled", command)
        self.assertIn("/app/kernel/request-talk-turn.uc", command)

    def test_summarize_elapsed_reports_percentiles(self):
        summary = kernel_invocation_audit.summarize_elapsed([10, 20, 30, 40])

        self.assertEqual(summary["count"], 4)
        self.assertEqual(summary["min"], 10)
        self.assertEqual(summary["max"], 40)
        self.assertEqual(summary["p50"], 30)

    def test_measurement_input_hash_is_stable_shape(self):
        case = {
            "id": "case-a",
            "kind": "request-talk-turn",
            "command": {"kind": "request-talk-turn"},
            "snapshot": {},
            "policy": {},
        }
        text = json.dumps(
            {"command": case["command"], "snapshot": case["snapshot"], "policy": case["policy"]},
            separators=(",", ":"),
            sort_keys=True,
        )

        self.assertEqual(len(kernel_invocation_audit.sha256_hex(text.encode())), 64)


if __name__ == "__main__":
    unittest.main()
