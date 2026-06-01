#!/usr/bin/env python3

from __future__ import annotations

import argparse
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import runtime_postgres_integration_proof


class RuntimePostgresIntegrationProofTests(unittest.TestCase):
    def test_required_proofs_pass_when_integration_step_passes(self) -> None:
        proofs = runtime_postgres_integration_proof.integration_proofs(
            [
                {
                    "name": "request-talk-turn-postgres-redis-integration-test",
                    "ok": True,
                }
            ]
        )

        self.assertEqual(
            {proof["name"] for proof in proofs},
            {proof["name"] for proof in runtime_postgres_integration_proof.REQUIRED_PROOFS},
        )
        self.assertTrue(all(proof["status"] == "pass" for proof in proofs))

    def test_required_proofs_are_blocked_when_integration_step_is_skipped(self) -> None:
        proofs = runtime_postgres_integration_proof.integration_proofs(
            [
                {
                    "name": "request-talk-turn-postgres-redis-integration-test",
                    "ok": False,
                    "skipped": True,
                    "reason": "Postgres/Redis services were not reachable",
                }
            ]
        )

        self.assertTrue(all(proof["status"] == "blocked" for proof in proofs))
        self.assertTrue(
            all(
                proof["reason"] == "Postgres/Redis services were not reachable"
                for proof in proofs
            )
        )

    def test_build_summary_requires_steps_and_proofs_to_pass(self) -> None:
        args = argparse.Namespace(
            compose_file="backend/infra/self-hosted/docker-compose.yml",
            database_url="postgres://example",
            redis_url="redis://example",
            preflight_output="/tmp/preflight.json",
            postgres_host="127.0.0.1",
            postgres_port=55432,
            redis_host="127.0.0.1",
            redis_port=56379,
        )
        summary = runtime_postgres_integration_proof.build_summary(
            args,
            [
                {"name": "self-hosted-preflight", "ok": True},
                {"name": "compose-up", "ok": True},
                {"name": "service-readiness", "ok": True},
                {
                    "name": "request-talk-turn-postgres-redis-integration-test",
                    "ok": True,
                },
            ],
        )

        self.assertTrue(summary["ok"])
        self.assertEqual(summary["status"], "pass")
        self.assertTrue(
            all(proof["status"] == "pass" for proof in summary["requiredProofs"])
        )


if __name__ == "__main__":
    unittest.main()
