#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import self_hosted_production_scenario_fuzz


class SelfHostedProductionScenarioFuzzTests(unittest.TestCase):
    def test_postgres_query_readiness_waits_for_successful_query(self) -> None:
        attempts = [
            {
                "name": "postgres-query-readiness",
                "ok": False,
                "stdout": "",
                "stderr": "database system is starting up",
            },
            {
                "name": "postgres-query-readiness",
                "ok": True,
                "stdout": "1\n",
                "stderr": "",
            },
        ]

        with mock.patch(
            "self_hosted_production_scenario_fuzz.run_command",
            side_effect=attempts,
        ) as run_command, mock.patch(
            "self_hosted_production_scenario_fuzz.time.sleep",
            return_value=None,
        ):
            result = self_hosted_production_scenario_fuzz.wait_for_postgres_query(
                "compose.yml", 5.0
            )

        self.assertTrue(result["ok"])
        self.assertEqual(run_command.call_count, 2)

    def test_postgres_query_readiness_reports_last_failed_result(self) -> None:
        failed = {
            "name": "postgres-query-readiness",
            "ok": False,
            "stdout": "",
            "stderr": "database system is starting up",
        }

        with mock.patch(
            "self_hosted_production_scenario_fuzz.run_command",
            return_value=failed,
        ), mock.patch(
            "self_hosted_production_scenario_fuzz.time.monotonic",
            side_effect=[0.0, 0.0, 2.0, 2.0],
        ), mock.patch(
            "self_hosted_production_scenario_fuzz.time.sleep",
            return_value=None,
        ):
            result = self_hosted_production_scenario_fuzz.wait_for_postgres_query(
                "compose.yml", 1.0
            )

        self.assertFalse(result["ok"])
        self.assertEqual(result["lastResult"], failed)


if __name__ == "__main__":
    unittest.main()
