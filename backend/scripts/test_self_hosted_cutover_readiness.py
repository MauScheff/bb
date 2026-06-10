#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import self_hosted_cutover_readiness


class SelfHostedCutoverReadinessTests(unittest.TestCase):
    def test_write_readiness_outputs_updates_current_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            output = root / "readiness.json"
            current = root / "current.json"
            summary = {"status": "not-ready", "ready": False, "ok": False}

            self_hosted_cutover_readiness.write_readiness_outputs(summary, output, current)

            self.assertEqual(summary, json.loads(output.read_text(encoding="utf-8")))
            self.assertEqual(summary, json.loads(current.read_text(encoding="utf-8")))

    def test_readiness_summary_exposes_ok_alias_for_ready_predicate(self) -> None:
        summary = self_hosted_cutover_readiness.build_readiness_summary(
            [
                {
                    "name": "kernel-golden-corpus",
                    "status": "pass",
                    "requiredForCutover": True,
                },
                {
                    "name": "physical-device-boundaries",
                    "status": "fail",
                    "requiredForCutover": True,
                },
                {
                    "name": "advisory-artifact",
                    "status": "missing",
                    "requiredForCutover": False,
                },
            ]
        )

        self.assertEqual("not-ready", summary["status"])
        self.assertFalse(summary["ready"])
        self.assertFalse(summary["ok"])
        self.assertEqual(
            ["physical-device-boundaries"],
            [item["name"] for item in summary["blockingEvidence"]],
        )

    def test_kernel_corpus_requires_stage_1a_case_coverage(self) -> None:
        cases = [
            self._kernel_case(
                "valid-request-talk-turn-grant", "request-talk-turn", "granted"
            ),
            self._kernel_case(
                "duplicate-request-denies-while-current-talk-turn-active",
                "request-talk-turn",
                "denied",
            ),
            self._kernel_case(
                "expired-current-talk-turn-can-be-replaced", "request-talk-turn", "granted"
            ),
            self._kernel_case(
                "ready-target-participant-grants", "request-talk-turn", "granted"
            ),
            self._kernel_case(
                "not-ready-target-participant-denies", "request-talk-turn", "denied"
            ),
            self._kernel_case(
                "wake-capable-target-device-grants", "request-talk-turn", "granted"
            ),
            self._kernel_case(
                "stale-device-readiness-denies", "request-talk-turn", "denied"
            ),
            self._kernel_case("missing-participant-denies", "request-talk-turn", "denied"),
            self._kernel_case(
                "malformed-snapshot-invalidates", "request-talk-turn", "invalid-snapshot"
            ),
        ]
        cases.append(
            self._kernel_case("stale-release-talk-turn-denies", "release-talk-turn", "denied")
        )

        result = self._check_kernel_corpus({"cases": cases})

        self.assertEqual(result["status"], "pass")

    def test_kernel_corpus_rejects_count_only_stale_artifact(self) -> None:
        result = self._check_kernel_corpus(
            {
                "cases": [
                    {
                        "id": f"old-case-{index}",
                        "kind": "request-talk-turn",
                        "expectedDecision": {},
                    }
                    for index in range(10)
                ]
            }
        )

        self.assertEqual(result["status"], "fail")
        self.assertIn("valid-request-talk-turn-grant", result["detail"])
        self.assertIn("stale-release-talk-turn-denies", result["detail"])

    def test_kernel_corpus_rejects_shallow_stage_1a_cases(self) -> None:
        cases = [
            self._kernel_case(
                "valid-request-talk-turn-grant", "request-talk-turn", "granted"
            ),
            self._kernel_case(
                "duplicate-request-denies-while-current-talk-turn-active",
                "request-talk-turn",
                "denied",
            ),
            self._kernel_case(
                "expired-current-talk-turn-can-be-replaced", "request-talk-turn", "granted"
            ),
            self._kernel_case(
                "ready-target-participant-grants", "request-talk-turn", "granted"
            ),
            self._kernel_case(
                "not-ready-target-participant-denies", "request-talk-turn", "denied"
            ),
            self._kernel_case(
                "wake-capable-target-device-grants", "request-talk-turn", "granted"
            ),
            self._kernel_case(
                "stale-device-readiness-denies", "request-talk-turn", "denied"
            ),
            self._kernel_case("missing-participant-denies", "request-talk-turn", "denied"),
            self._kernel_case(
                "malformed-snapshot-invalidates", "request-talk-turn", "invalid-snapshot"
            ),
            self._kernel_case("stale-release-talk-turn-denies", "release-talk-turn", "denied"),
        ]
        cases[0].pop("snapshot")
        cases[1]["expectedDecision"].pop("reason")
        cases[5]["expectedDecision"]["effectPlan"]["postCommitEffects"] = [
            {"kind": "notify-talk-turn-granted"}
        ]

        result = self._check_kernel_corpus({"cases": cases})

        self.assertEqual(result["status"], "fail")
        self.assertIn("valid-request-talk-turn-grant", result["detail"])
        self.assertIn(
            "duplicate-request-denies-while-current-talk-turn-active:reason=missing",
            result["detail"],
        )
        self.assertIn(
            "wake-capable-target-device-grants:wake-target-device=missing",
            result["detail"],
        )

    def test_kernel_corpus_rejects_duplicate_stage_1a_case_ids(self) -> None:
        case = self._kernel_case(
            "valid-request-talk-turn-grant", "request-talk-turn", "granted"
        )

        result = self._check_kernel_corpus({"cases": [case, case]})

        self.assertEqual(result["status"], "fail")
        self.assertIn("duplicateCases=['valid-request-talk-turn-grant']", result["detail"])

    def test_http_probe_passes_with_current_native_and_legacy_evidence(self) -> None:
        payload = {
            "status": "ok",
            "health_ok": True,
            "bootstrap_ok": True,
            "discovery_ok": True,
            "native_granted": True,
            "prefixed_native_granted": True,
            "native_renewed": True,
            "native_released": True,
            "legacy_transmitting": True,
            "legacy_renew_transmitting": True,
            "legacy_end_stopped": True,
            "bad_request_rejected": True,
            "observations": self._http_route_observations(),
            "steps": [
                "app-compatible /s/turbo health route served over TCP",
                "app-compatible runtime config route served over TCP",
                "app-compatible auth session route served over TCP",
                "app-compatible device registration route served over TCP",
                "app-compatible presence keepalive route served over TCP",
                "app-compatible telemetry events route served over TCP",
                "app-compatible user lookup route served over TCP",
                "app-compatible user presence lookup route served over TCP",
                "app-compatible identity resolve route served over TCP",
                "app-compatible direct channel route served over TCP",
                "app-compatible channel join route served over TCP",
                "app-compatible peer channel join route served over TCP",
                "app-compatible channel state route served over TCP",
                "app-compatible channel readiness route served over TCP",
                "app-compatible receiver audio readiness route served over TCP",
                "app-compatible beep list routes served over TCP",
                "native RequestTalkTurn route served over TCP",
                "app-compatible /s/turbo RequestTalkTurn route served over TCP",
                "native RenewTalkTurn route served over TCP",
                "native ReleaseTalkTurn route served over TCP",
                "legacy begin-transmit compatibility route served over TCP",
                "legacy renew-transmit compatibility route served over TCP",
                "legacy end-transmit compatibility route served over TCP",
                "mismatched Conversation path rejected over TCP",
            ],
        }

        result = self._check_http_probe(payload)

        self.assertEqual(result["status"], "pass")
        self.assertIn("observations=25", result["detail"])

    def test_http_probe_rejects_top_level_pass_without_route_steps(self) -> None:
        payload = {
            "status": "ok",
            "health_ok": True,
            "bootstrap_ok": True,
            "discovery_ok": True,
            "native_granted": True,
            "prefixed_native_granted": True,
            "native_renewed": True,
            "native_released": True,
            "legacy_transmitting": True,
            "legacy_renew_transmitting": True,
            "legacy_end_stopped": True,
            "bad_request_rejected": True,
            "steps": [],
        }

        result = self._check_http_probe(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("missingSteps", result["detail"])
        self.assertIn("app-compatible /s/turbo health route served over TCP", result["detail"])

    def test_http_probe_rejects_stale_artifact_without_renew_release_evidence(self) -> None:
        payload = {
            "status": "ok",
            "health_ok": True,
            "bootstrap_ok": True,
            "discovery_ok": True,
            "native_granted": True,
            "prefixed_native_granted": True,
            "legacy_transmitting": True,
            "bad_request_rejected": True,
        }

        result = self._check_http_probe(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("native_renewed", result["detail"])
        self.assertIn("native_released", result["detail"])
        self.assertIn("legacy_renew_transmitting", result["detail"])
        self.assertIn("legacy_end_stopped", result["detail"])

    def test_websocket_probe_passes_with_current_single_and_cluster_evidence(self) -> None:
        payload = {
            "status": "ok",
            "routed_initial_payload": True,
            "stale_connection_rejected": True,
            "routed_reconnected_payload": True,
            "reconnected_session_id": "1",
            "real_network_routed_payload": True,
            "real_network_stale_connection_rejected": True,
            "real_network_reconnected_session_id": "1",
            "app_compatible_handshake_ok": True,
            "app_compatible_cluster_owner_routed_payload": True,
            "app_compatible_authorization_facts_recorded": True,
            "observations": self._websocket_observations(),
            "steps": [
                "connected participant-a/device-a",
                "connected participant-b/device-b on initial socket",
                "routed initial direct-quic-offer to connected target",
                "disconnected initial target socket",
                "reconnected target device on replacement socket",
                "verified stale socket lost command authority",
                "routed replacement direct-quic-offer to reconnected socket",
                "network: client-a connected over TCP/WebSocket",
                "network: client-b initial socket connected over TCP/WebSocket",
                "network: routed initial signal between two real sockets",
                "network: client-b replacement socket connected over TCP/WebSocket",
                "network: stale client-b socket rejected after reconnect",
                "network: routed replacement signal to reconnected real socket",
                "app-compatible-cluster: two app-compatible clients completed clustered handshakes",
                "app-compatible-cluster: owner-routed clustered signal reached the target socket",
                "app-compatible-cluster: clustered authorization facts were recorded to the configured sink",
            ],
        }

        result = self._check_websocket_probe(payload)

        self.assertEqual(result["status"], "pass")
        self.assertIn("observations=16", result["detail"])

    def test_websocket_probe_rejects_top_level_pass_without_route_steps(self) -> None:
        payload = {
            "status": "ok",
            "routed_initial_payload": True,
            "stale_connection_rejected": True,
            "routed_reconnected_payload": True,
            "reconnected_session_id": "1",
            "real_network_routed_payload": True,
            "real_network_stale_connection_rejected": True,
            "real_network_reconnected_session_id": "1",
            "app_compatible_handshake_ok": True,
            "app_compatible_cluster_owner_routed_payload": True,
            "app_compatible_authorization_facts_recorded": True,
            "steps": [],
        }

        result = self._check_websocket_probe(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("missingSteps", result["detail"])
        self.assertIn("connected participant-a/device-a", result["detail"])

    def test_websocket_probe_rejects_stale_artifact_without_cluster_evidence(self) -> None:
        payload = {
            "status": "ok",
            "routed_initial_payload": True,
            "stale_connection_rejected": True,
            "routed_reconnected_payload": True,
            "reconnected_session_id": "1",
            "real_network_routed_payload": True,
            "real_network_stale_connection_rejected": True,
            "real_network_reconnected_session_id": "1",
        }

        result = self._check_websocket_probe(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("app_compatible_handshake_ok", result["detail"])
        self.assertIn("app_compatible_cluster_owner_routed_payload", result["detail"])
        self.assertIn("app_compatible_authorization_facts_recorded", result["detail"])

    def test_runtime_control_probe_passes_with_current_transport_evidence(self) -> None:
        result = self._check_runtime_control_probe(self._runtime_control_probe_payload())

        self.assertEqual(result["name"], "runtime-control-probe")
        self.assertEqual(result["status"], "pass")
        self.assertIn("checks=5", result["detail"])

    def test_runtime_control_probe_rejects_top_level_pass_without_required_checks(self) -> None:
        payload = {
            "status": "ok",
            "ok": True,
            "checks": [
                {
                    "name": "runtime-quic-control",
                    "ok": True,
                    "exitCode": 0,
                    "command": ["cargo", "test"],
                }
            ],
        }

        result = self._check_runtime_control_probe(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("runtime-tls-control", result["detail"])
        self.assertIn("runtime-websocket-retired-by-default", result["detail"])

    def test_runtime_control_probe_rejects_failed_lane_check(self) -> None:
        payload = self._runtime_control_probe_payload()
        payload["checks"][1]["ok"] = False
        payload["checks"][1]["exitCode"] = 101

        result = self._check_runtime_control_probe(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("runtime-tls-control.ok=False", result["detail"])
        self.assertIn("runtime-tls-control.exitCode=101", result["detail"])

    def test_fuzz_artifact_passes_with_expected_gate_and_iteration_checks(self) -> None:
        payload = {
            "status": "ok",
            "gate": "rust-runtime-fuzz",
            "requested_count": 16,
            "seed": 123,
            "checks": [f"rust-runtime iteration {index}" for index in range(16)],
        }

        result = self._check_fuzz_artifact(payload)

        self.assertEqual(result["status"], "pass")

    def test_fuzz_artifact_rejects_empty_or_wrong_gate_report(self) -> None:
        payload = {
            "status": "ok",
            "gate": "old-fuzz-gate",
            "requested_count": 0,
            "seed": 123,
            "checks": [],
        }

        result = self._check_fuzz_artifact(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("old-fuzz-gate", result["detail"])
        self.assertIn("requested_count=0", result["detail"])
        self.assertIn("rust-runtime iteration checks=0", result["detail"])

    def test_fuzz_artifact_rejects_duplicate_or_non_contiguous_iterations(self) -> None:
        payload = {
            "status": "ok",
            "gate": "rust-runtime-fuzz",
            "requested_count": 16,
            "seed": 123,
            "checks": [
                *[f"rust-runtime iteration {index}" for index in range(16) if index != 2],
                "rust-runtime iteration 1",
            ],
        }

        result = self._check_fuzz_artifact(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("checks=duplicates", result["detail"])
        self.assertIn("missingIterations=[2]", result["detail"])

    def test_rust_runtime_fuzz_requires_runtime_boundary_observations(self) -> None:
        payload = self._rust_runtime_fuzz_payload()

        result = self._check_rust_runtime_fuzz(payload)

        self.assertEqual(result["status"], "pass")
        self.assertIn("observations=80", result["detail"])
        self.assertIn("runtime-quic-payload-boundary", result["detail"])

    def test_rust_runtime_fuzz_rejects_label_only_artifact(self) -> None:
        payload = self._rust_runtime_fuzz_payload()
        payload.pop("observations")

        result = self._check_rust_runtime_fuzz(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("observations=missing", result["detail"])
        self.assertIn("iteration 0 missingObservations", result["detail"])

    def test_rust_runtime_fuzz_rejects_missing_boundary_observation(self) -> None:
        payload = self._rust_runtime_fuzz_payload()
        payload["observations"] = [
            observation
            for observation in payload["observations"]
            if not (
                observation["iteration"] == 3
                and observation["kind"] == "runtime-owner-routing"
            )
        ]

        result = self._check_rust_runtime_fuzz(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("iteration 3 missingObservations", result["detail"])
        self.assertIn("runtime-owner-routing", result["detail"])

    def test_reliability_fuzz_requires_runtime_and_shadow_observations(self) -> None:
        payload = self._reliability_fuzz_payload()

        result = self._check_reliability_fuzz(payload)

        self.assertEqual(result["status"], "pass")
        self.assertIn("observations=12", result["detail"])
        self.assertIn("shadowObservations=2", result["detail"])

    def test_reliability_fuzz_rejects_label_only_artifact(self) -> None:
        payload = self._reliability_fuzz_payload()
        payload.pop("observations")

        result = self._check_reliability_fuzz(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("observations=missing", result["detail"])
        self.assertIn("runtime iteration 0 missingObservations", result["detail"])
        self.assertIn("shadow iteration 0 observation=missing", result["detail"])

    def test_reliability_fuzz_rejects_missing_shadow_observation(self) -> None:
        payload = self._reliability_fuzz_payload()
        payload["observations"] = [
            observation
            for observation in payload["observations"]
            if not (
                observation["iteration"] == 1
                and observation["kind"] == "shadow-begin-transmit-vs-request-talk-turn"
            )
        ]

        result = self._check_reliability_fuzz(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("shadow iteration 1 observation=missing", result["detail"])

    def test_self_hosted_scenario_fuzz_requires_production_runtime_iterations(self) -> None:
        payload = {
            "status": "ok",
            "gate": "self-hosted-scenario-fuzz-local",
            "requested_count": 3,
            "seed": 123,
            "checks": [
                "self-hosted scenario iteration 0",
                "self-hosted scenario iteration 1",
                "self-hosted scenario iteration 2",
            ],
        }

        result = self._check_self_hosted_scenario_fuzz(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("production-runtime scenario iteration checks=0", result["detail"])

    def test_self_hosted_scenario_fuzz_requires_production_runtime_steps(self) -> None:
        payload = self._self_hosted_scenario_fuzz_payload()

        result = self._check_self_hosted_scenario_fuzz(payload)

        self.assertEqual(result["status"], "pass")
        self.assertIn("productionScenarios=3", result["detail"])

    def test_self_hosted_scenario_fuzz_rejects_label_only_production_runtime_pass(
        self,
    ) -> None:
        payload = self._self_hosted_scenario_fuzz_payload()
        payload["steps"] = []

        result = self._check_self_hosted_scenario_fuzz(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("self-hosted-preflight=missing", result["detail"])
        self.assertIn("production-runtime-scenario-0=missing", result["detail"])

    def test_self_hosted_scenario_fuzz_rejects_incomplete_talk_turn_flow(self) -> None:
        payload = self._self_hosted_scenario_fuzz_payload()
        scenario = payload["steps"][-1]
        scenario["release"]["status"] = "still-transmitting"

        result = self._check_self_hosted_scenario_fuzz(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("production-runtime-scenario-2:release=not-released", result["detail"])

    def test_shadow_backend_fuzz_requires_normalized_comparison_observations(self) -> None:
        payload = {
            "status": "ok",
            "gate": "shadow-backend-fuzz",
            "requested_count": 8,
            "seed": 123,
            "checks": [f"shadow comparison iteration {index}" for index in range(8)],
            "observations": [
                self._shadow_observation(index, "equivalent" if index != 4 else "divergent")
                for index in range(8)
            ],
        }

        result = self._check_shadow_backend_fuzz(payload)

        self.assertEqual(result["status"], "pass")
        self.assertIn("observations=8", result["detail"])
        self.assertIn("divergent", result["detail"])

    def test_shadow_backend_fuzz_rejects_label_only_artifact(self) -> None:
        payload = {
            "status": "ok",
            "gate": "shadow-backend-fuzz",
            "requested_count": 8,
            "seed": 123,
            "checks": [f"shadow comparison iteration {index}" for index in range(8)],
        }

        result = self._check_shadow_backend_fuzz(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("observations=missing", result["detail"])
        self.assertIn("divergentVerdict=missing", result["detail"])

    def test_shadow_backend_fuzz_rejects_observations_without_divergence(self) -> None:
        payload = {
            "status": "ok",
            "gate": "shadow-backend-fuzz",
            "requested_count": 8,
            "seed": 123,
            "checks": [f"shadow comparison iteration {index}" for index in range(8)],
            "observations": [
                self._shadow_observation(index, "equivalent") for index in range(8)
            ],
        }

        result = self._check_shadow_backend_fuzz(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("divergentVerdict=missing", result["detail"])

    def test_self_hosted_preflight_reports_docker_substrate_without_failed_service_noise(
        self,
    ) -> None:
        payload = {
            "status": "pass",
            "ok": True,
            "substrate": "docker-compose",
            "dockerReady": True,
            "existingServicesReady": False,
            "steps": [
                {"name": "docker-cli", "ok": True},
                {"name": "compose-file", "ok": True},
                {"name": "compose-config", "ok": True},
                {"name": "docker-daemon", "ok": True},
                {"name": "postgres-tcp", "ok": False},
                {"name": "redis-tcp", "ok": False},
            ],
        }

        result = self._check_self_hosted_preflight(payload)

        self.assertEqual(result["status"], "pass")
        self.assertIn("substrate='docker-compose'", result["detail"])
        self.assertIn("existingServicesReady=False", result["detail"])
        self.assertNotIn("failedSteps", result["detail"])

    def test_self_hosted_preflight_reports_failed_steps_when_artifact_fails(self) -> None:
        payload = {
            "status": "fail",
            "ok": False,
            "substrate": "none",
            "dockerReady": False,
            "existingServicesReady": False,
            "steps": [
                {"name": "compose-config", "ok": False},
                {"name": "docker-daemon", "ok": False},
            ],
        }

        result = self._check_self_hosted_preflight(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("status='fail'", result["detail"])
        self.assertIn("compose-config", result["detail"])

    def test_self_hosted_preflight_rejects_top_level_pass_without_substrate_steps(self) -> None:
        payload = {
            "status": "pass",
            "ok": True,
            "substrate": "docker-compose",
            "dockerReady": True,
            "existingServicesReady": False,
            "steps": [],
        }

        result = self._check_self_hosted_preflight(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("docker-cli=missing", result["detail"])
        self.assertIn("compose-config=missing", result["detail"])

    def test_talk_turn_actor_model_requires_configured_invariants_and_tlc_states(self) -> None:
        payload = {
            "status": "pass",
            "ok": True,
            "spec": "backend/specs/tla/TurboTalkTurnActor.tla",
            "config": "backend/specs/tla/TurboTalkTurnActor.cfg",
            "steps": [
                {
                    "name": "tla-config-validation",
                    "ok": True,
                    "hasSpecification": True,
                    "configuredInvariants": [
                        "TypeOK",
                        "OneRuntimeOwnerPerConversation",
                        "AtMostOneActiveTalkTurn",
                        "StaleReleaseCannotClearNewerGrant",
                        "ActiveTalkTurnLeaseIsCurrent",
                        "PolicyDowngradeRevokesActiveGrant",
                        "DrainRequiresReconnectWithoutDurableLoss",
                        "DrainingDoesNotGrant",
                        "ActiveTalkTurnHasOwner",
                        "ActiveTalkTurnParticipantsConnected",
                    ],
                    "missingDefinitions": [],
                    "missingRequiredInvariants": [],
                },
                {
                    "name": "tlc",
                    "ok": True,
                    "exitCode": 0,
                    "outputPath": "/tmp/tlc-output.txt",
                    "summary": [
                        "Model checking completed. No error has been found.",
                        "11409 states generated, 1968 distinct states found, 0 states left on queue.",
                    ],
                },
            ],
        }

        result = self._check_model_artifact(payload)

        self.assertEqual("pass", result["status"])
        self.assertIn("configuredInvariants=10", result["detail"])

    def test_talk_turn_actor_model_rejects_top_level_pass_without_tlc_contract(self) -> None:
        payload = {
            "status": "pass",
            "ok": True,
            "spec": "backend/specs/tla/TurboTalkTurnActor.tla",
            "config": "backend/specs/tla/TurboTalkTurnActor.cfg",
            "steps": [
                {
                    "name": "tla-config-validation",
                    "ok": True,
                    "hasSpecification": True,
                    "configuredInvariants": ["TypeOK"],
                    "missingDefinitions": [],
                    "missingRequiredInvariants": [],
                }
            ],
        }

        result = self._check_model_artifact(payload)

        self.assertEqual("fail", result["status"])
        self.assertIn("missingRequiredInvariants", result["detail"])
        self.assertIn("tlc=missing", result["detail"])

    def test_physical_boundaries_reports_failed_cells(self) -> None:
        payload = {
            "status": "fail",
            "ok": False,
            "manifestEvidenceSince": "2026-06-01T04:00:00Z",
            "sourceEvidenceWindows": [
                {
                    "sourceManifest": "/tmp/run/physical-device-boundaries-manifest.json",
                    "evidenceSince": "2026-06-01T04:00:00Z",
                }
            ],
            "cells": [
                {
                    "name": "foreground-ptt-audio",
                    "status": "fail",
                    "reason": "device ids contain placeholders",
                }
            ],
        }

        result = self._check_physical_boundaries(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("foreground-ptt-audio", result["detail"])
        self.assertIn("device ids contain placeholders", result["detail"])
        self.assertIn("foregrounded", result["remediation"])
        self.assertIn("physical-device-boundary-status", result["remediation"])
        self.assertEqual("2026-06-01T04:00:00Z", result["physicalEvidenceWindow"]["manifestEvidenceSince"])
        self.assertEqual(
            "2026-06-01T04:00:00Z",
            result["physicalEvidenceWindow"]["sourceEvidenceWindows"][0]["evidenceSince"],
        )
        self.assertEqual(
            "/tmp/turbo-physical-device-boundary-status-current.json",
            result["operatorStatusArtifact"],
        )
        commands = {command["name"]: command["command"] for command in result["nextCommands"]}
        self.assertIn("collect-foreground-ptt-audio", commands)
        self.assertIn("inspect-physical-device-boundary-status", commands)
        self.assertIn("finalize-canonical-physical-proof", commands)

    def test_physical_boundaries_reports_direct_quic_and_wake_next_commands(self) -> None:
        payload = {
            "status": "fail",
            "ok": False,
            "cells": [
                {
                    "name": "direct-quic-media",
                    "status": "fail",
                    "reason": "missing required context anchors",
                },
                {
                    "name": "lockscreen-apns-wake",
                    "status": "fail",
                    "reason": "missing incoming push received on locked/background receiver",
                },
            ],
        }

        result = self._check_physical_boundaries(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("Direct QUIC", result["remediation"])
        self.assertIn("PushToTalk APNs wake", result["remediation"])
        commands = {command["name"]: command["command"] for command in result["nextCommands"]}
        self.assertEqual("just device-launch-connected-json", commands["verify-device-launchability"])
        self.assertIn("--target-cell direct-quic-media", commands["collect-direct-quic-media"])
        self.assertIn("/tmp/turbo-physical-direct-quic-run-current \"\" direct-quic", commands["collect-direct-quic-media"])
        self.assertIn("--send-wake-apns", commands["collect-lockscreen-apns-wake"])
        self.assertIn("<channel-id>", commands["collect-lockscreen-apns-wake"])
        self.assertIn(
            "--run /tmp/turbo-physical-direct-quic-run-current",
            commands["inspect-physical-device-boundary-status"],
        )
        self.assertIn("/tmp/turbo-physical-direct-quic-run-current", commands["finalize-canonical-physical-proof"])
        self.assertIn("/tmp/turbo-physical-lockscreen-wake-run", commands["finalize-canonical-physical-proof"])
        self.assertIn("/tmp/turbo-physical-fallback-relay-run", commands["finalize-canonical-physical-proof"])
        self.assertIn("/tmp/turbo-physical-foreground-ptt-run", commands["finalize-canonical-physical-proof"])

    def test_physical_boundaries_attaches_launchability_summary_when_status_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            status_path = root / "status.json"
            status_path.write_text(
                json.dumps(
                    {
                        "currentLaunchabilityProbe": {
                            "artifact": "/tmp/turbo-device-launch-connected-current.json",
                            "status": "fail",
                            "ok": False,
                            "launchablePhysicalDeviceCount": 0,
                            "failedPhysicalDeviceCount": 2,
                            "failureReasons": ["locked"],
                            "devices": [
                                {
                                    "name": "iPhone",
                                    "udid": "physical-1",
                                    "ok": False,
                                    "reason": "locked",
                                },
                                {
                                    "name": "iPad",
                                    "udid": "physical-2",
                                    "ok": False,
                                    "reason": "locked",
                                },
                            ],
                        }
                    }
                ),
                encoding="utf-8",
            )
            old_path = self_hosted_cutover_readiness.DEFAULT_ARTIFACTS["physicalDeviceBoundaryStatus"]
            self_hosted_cutover_readiness.DEFAULT_ARTIFACTS["physicalDeviceBoundaryStatus"] = str(status_path)
            try:
                result = self._check_physical_boundaries(
                    {
                        "status": "fail",
                        "ok": False,
                        "cells": [
                            {
                                "name": "direct-quic-media",
                                "status": "fail",
                                "reason": "missing context",
                            }
                        ],
                    }
                )
            finally:
                self_hosted_cutover_readiness.DEFAULT_ARTIFACTS["physicalDeviceBoundaryStatus"] = old_path

        self.assertEqual("fail", result["launchabilitySummary"]["status"])
        self.assertEqual(["locked"], result["launchabilitySummary"]["failureReasons"])
        self.assertEqual(0, result["launchabilitySummary"]["launchablePhysicalDeviceCount"])
        self.assertEqual("iPhone", result["launchabilitySummary"]["devices"][0]["name"])

    def test_physical_boundaries_attaches_compact_priority_actions_when_status_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            status_path = root / "status.json"
            status_path.write_text(
                json.dumps(
                    {
                        "priorityActions": [
                            {
                                "kind": "resolve-launch-failure",
                                "cell": "direct-quic-media",
                                "device": "iPhone",
                                "reason": "locked",
                                "summary": "iPhone: locked",
                                "remediation": "Unlock this device.",
                                "verificationCommand": "just device-launch-connected-json",
                                "verificationArtifact": "/tmp/turbo-device-launch-connected-current.json",
                                "currentLaunchabilityProbe": "locked",
                            },
                            {
                                "kind": "rerun-missing-cell",
                                "cell": "lockscreen-apns-wake",
                                "summary": "Rerun lockscreen-apns-wake.",
                                "command": "just physical-device-boundary-collect ...",
                                "sendWakeApnsResult": {
                                    "ok": False,
                                    "stage": "backend-push-target",
                                    "channelId": "dummy-channel",
                                    "handle": "@dummy",
                                    "error": "target missing",
                                    "body": "not found",
                                    "ignoredRawBody": "large body",
                                },
                                "wakeSendDiagnosis": {
                                    "kind": "not-channel-member",
                                    "summary": "sender not member",
                                    "remediation": "use a live channel and sender member",
                                },
                                "finalizeFailure": {
                                    "name": "lockscreen-apns-wake",
                                    "reason": "missing wake evidence",
                                },
                            },
                        ]
                    }
                ),
                encoding="utf-8",
            )
            old_path = self_hosted_cutover_readiness.DEFAULT_ARTIFACTS["physicalDeviceBoundaryStatus"]
            self_hosted_cutover_readiness.DEFAULT_ARTIFACTS["physicalDeviceBoundaryStatus"] = str(status_path)
            try:
                result = self._check_physical_boundaries(
                    {
                        "status": "fail",
                        "ok": False,
                        "cells": [
                            {
                                "name": "direct-quic-media",
                                "status": "fail",
                                "reason": "missing context",
                            },
                            {
                                "name": "lockscreen-apns-wake",
                                "status": "fail",
                                "reason": "missing wake",
                            },
                        ],
                    }
                )
            finally:
                self_hosted_cutover_readiness.DEFAULT_ARTIFACTS["physicalDeviceBoundaryStatus"] = old_path

        self.assertEqual("resolve-launch-failure", result["physicalPriorityActions"][0]["kind"])
        self.assertEqual("just device-launch-connected-json", result["physicalPriorityActions"][0]["verificationCommand"])
        self.assertEqual("backend-push-target", result["physicalPriorityActions"][1]["sendWakeApnsResult"]["stage"])
        self.assertEqual("dummy-channel", result["physicalPriorityActions"][1]["sendWakeApnsResult"]["channelId"])
        self.assertEqual("not found", result["physicalPriorityActions"][1]["sendWakeApnsResult"]["body"])
        self.assertNotIn("ignoredRawBody", result["physicalPriorityActions"][1]["sendWakeApnsResult"])
        self.assertEqual("not-channel-member", result["physicalPriorityActions"][1]["wakeSendDiagnosis"]["kind"])
        self.assertEqual("missing wake evidence", result["physicalPriorityActions"][1]["finalizeFailure"]["reason"])

    def test_physical_boundaries_attaches_finalize_summary_when_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            finalize_path = root / "finalize.json"
            finalize_path.write_text(
                json.dumps(
                    {
                        "status": "fail",
                        "ok": False,
                        "skippedMissingInputs": [
                            "/tmp/turbo-physical-fallback-relay-run",
                            "/tmp/turbo-physical-foreground-ptt-run",
                        ],
                        "resolvedManifests": [
                            "/tmp/turbo-physical-direct-quic-run-current/physical-device-boundaries-manifest.json",
                        ],
                        "proofSummary": {
                            "passedCells": [],
                            "failedCells": [
                                {
                                    "name": "direct-quic-media",
                                    "reason": "missing Direct QUIC evidence",
                                }
                            ],
                        },
                    }
                ),
                encoding="utf-8",
            )
            old_path = self_hosted_cutover_readiness.DEFAULT_ARTIFACTS["physicalDeviceBoundaryFinalize"]
            self_hosted_cutover_readiness.DEFAULT_ARTIFACTS["physicalDeviceBoundaryFinalize"] = str(finalize_path)
            try:
                result = self._check_physical_boundaries(
                    {
                        "status": "fail",
                        "ok": False,
                        "cells": [
                            {
                                "name": "direct-quic-media",
                                "status": "fail",
                                "reason": "missing Direct QUIC evidence",
                            }
                        ],
                    }
                )
            finally:
                self_hosted_cutover_readiness.DEFAULT_ARTIFACTS["physicalDeviceBoundaryFinalize"] = old_path

        summary = result["physicalFinalizeSummary"]
        self.assertEqual("fail", summary["status"])
        self.assertEqual(["/tmp/turbo-physical-fallback-relay-run", "/tmp/turbo-physical-foreground-ptt-run"], summary["skippedMissingInputs"])
        self.assertEqual("direct-quic-media", summary["failedCells"][0]["name"])

    def test_simulator_suite_requires_self_hosted_preflight_scenario_and_strict_diagnostics(self) -> None:
        payload = {
            "status": "pass",
            "ok": True,
            "baseUrl": "http://127.0.0.1:8091/s/turbo",
            "handleA": "@avery",
            "handleB": "@blake",
            "deviceIDA": "sim-self-hosted-avery-123",
            "deviceIDB": "sim-self-hosted-blake-123",
            "steps": [
                {
                    "name": "self-hosted-health-preflight",
                    "ok": True,
                    "checks": [
                        {
                            "name": "health",
                            "ok": True,
                            "body": {
                                "runtime": "self-hosted",
                                "supportsWebSocket": False,
                            },
                        },
                        {
                            "name": "config",
                            "ok": True,
                            "body": {
                                "mode": "self-hosted",
                                "supportsWebSocket": False,
                            },
                        },
                    ],
                },
                {
                    "name": "simulator-scenario-suite-self-hosted",
                    "ok": True,
                    "exitCode": 0,
                    "stdout": self._simulator_scenario_stdout(),
                    "command": [
                        "python3",
                        "tools/scripts/run_simulator_scenarios.py",
                        "--base-url",
                        "http://127.0.0.1:8091/s/turbo",
                    ],
                },
                {
                    "name": "simulator-self-hosted-merged-diagnostics-strict",
                    "ok": True,
                    "exitCode": 0,
                    "command": [
                        "python3",
                        "tools/scripts/merged_diagnostics.py",
                        "--base-url",
                        "http://127.0.0.1:8091/s/turbo",
                        "--no-telemetry",
                        "--fail-on-violations",
                        "--device",
                        "@avery=sim-self-hosted-avery-123",
                        "--device",
                        "@blake=sim-self-hosted-blake-123",
                    ],
                },
            ],
        }

        result = self._check_simulator_suite(payload)

        self.assertEqual("pass", result["status"])

    def test_simulator_suite_rejects_shallow_scenario_command_success(self) -> None:
        payload = {
            "status": "pass",
            "ok": True,
            "baseUrl": "http://127.0.0.1:8091/s/turbo",
            "handleA": "@avery",
            "handleB": "@blake",
            "deviceIDA": "sim-self-hosted-avery-123",
            "deviceIDB": "sim-self-hosted-blake-123",
            "steps": [
                {
                    "name": "self-hosted-health-preflight",
                    "ok": True,
                    "checks": [
                        {
                            "name": "health",
                            "ok": True,
                            "body": {
                                "runtime": "self-hosted",
                                "supportsWebSocket": False,
                            },
                        },
                        {
                            "name": "config",
                            "ok": True,
                            "body": {
                                "mode": "self-hosted",
                                "supportsWebSocket": False,
                            },
                        },
                    ],
                },
                {
                    "name": "simulator-scenario-suite-self-hosted",
                    "ok": True,
                    "exitCode": 0,
                    "stdout": "** TEST SUCCEEDED **\n",
                    "command": [
                        "python3",
                        "tools/scripts/run_simulator_scenarios.py",
                        "--base-url",
                        "http://127.0.0.1:8091/s/turbo",
                    ],
                },
                {
                    "name": "simulator-self-hosted-merged-diagnostics-strict",
                    "ok": True,
                    "exitCode": 0,
                    "command": [
                        "python3",
                        "tools/scripts/merged_diagnostics.py",
                        "--base-url",
                        "http://127.0.0.1:8091/s/turbo",
                        "--no-telemetry",
                        "--fail-on-violations",
                        "--device",
                        "@avery=sim-self-hosted-avery-123",
                        "--device",
                        "@blake=sim-self-hosted-blake-123",
                    ],
                },
            ],
        }

        result = self._check_simulator_suite(payload)

        self.assertEqual("fail", result["status"])
        self.assertIn("scenarioRunMarkers=0", result["detail"])
        self.assertIn("scenarioFinishMarkers=0", result["detail"])

    def test_simulator_suite_rejects_stale_top_level_pass_without_required_steps(self) -> None:
        result = self._check_simulator_suite(
            {
                "status": "pass",
                "ok": True,
                "baseUrl": "http://127.0.0.1:8091/s/turbo",
                "steps": [],
            }
        )

        self.assertEqual("fail", result["status"])
        self.assertIn("self-hosted-health-preflight=missing", result["detail"])
        self.assertIn("simulator-scenario-suite-self-hosted=missing", result["detail"])
        self.assertIn("simulator-self-hosted-merged-diagnostics-strict=missing", result["detail"])

    def test_simulator_suite_reports_self_hosted_preflight_failures(self) -> None:
        payload = {
            "status": "fail",
            "ok": False,
            "steps": [
                {
                    "name": "self-hosted-health-preflight",
                    "ok": False,
                    "checks": [
                        {
                            "name": "health",
                            "ok": False,
                            "url": "http://127.0.0.1:8091/s/turbo/v1/health",
                            "error": "connection refused",
                        },
                        {
                            "name": "config",
                            "ok": False,
                            "url": "http://127.0.0.1:8091/s/turbo/v1/config",
                            "error": "connection refused",
                        },
                    ],
                }
            ],
        }

        result = self._check_simulator_suite(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("preflightFailures", result["detail"])
        self.assertIn("/v1/config", result["detail"])

    def test_hosted_simulator_count_excludes_local_only_scenarios(self) -> None:
        local_count = self_hosted_cutover_readiness.checked_in_simulator_scenario_count(
            "http://127.0.0.1:8091/s/turbo"
        )
        hosted_count = self_hosted_cutover_readiness.checked_in_simulator_scenario_count(
            "https://api.beepbeep.to/s/turbo"
        )

        self.assertGreater(local_count, hosted_count)
        self.assertEqual(38, local_count)
        self.assertEqual(26, hosted_count)

    def test_rust_postgres_integration_requires_named_live_proofs(self) -> None:
        proof_names = [
            "postgres-schema-application",
            "postgres-snapshot-loader",
            "talk-turn-db-constraints",
            "kernel-replay-idempotency",
            "post-commit-outbox-delivery",
            "websocket-authorization-facts",
            "redis-owner-record-cas",
        ]
        payload = {
            "status": "pass",
            "ok": True,
            "requiredProofs": [
                {
                    "name": name,
                    "status": "pass",
                    "ok": True,
                    "sourceStep": "request-talk-turn-postgres-redis-integration-test",
                }
                for name in proof_names
            ],
            "steps": [
                {
                    "name": "self-hosted-preflight",
                    "ok": True,
                    "exitCode": 0,
                },
                {
                    "name": "compose-up",
                    "ok": True,
                    "exitCode": 0,
                },
                {
                    "name": "service-readiness",
                    "ok": True,
                    "checks": [
                        {"name": "postgres-tcp", "ok": True},
                        {"name": "redis-tcp", "ok": True},
                    ],
                },
                {
                    "name": "request-talk-turn-postgres-redis-integration-test",
                    "ok": True,
                    "exitCode": 0,
                    "command": [
                        "cargo",
                        "test",
                        "-q",
                        "-p",
                        "beepbeep-runtime",
                        "--test",
                        "request_talk_turn_integration",
                        "--",
                        "--ignored",
                    ],
                },
            ],
        }

        result = self._check_rust_postgres_integration(payload)

        self.assertEqual(result["status"], "pass")

    def test_rust_postgres_integration_rejects_named_proofs_without_live_steps(self) -> None:
        payload = {
            "status": "pass",
            "ok": True,
            "requiredProofs": [
                {"name": name, "status": "pass", "ok": True}
                for name in [
                    "postgres-schema-application",
                    "postgres-snapshot-loader",
                    "talk-turn-db-constraints",
                    "kernel-replay-idempotency",
                    "post-commit-outbox-delivery",
                    "websocket-authorization-facts",
                    "redis-owner-record-cas",
                ]
            ],
            "steps": [],
        }

        result = self._check_rust_postgres_integration(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("self-hosted-preflight=missing", result["detail"])
        self.assertIn("service-readiness=missing", result["detail"])
        self.assertIn("request-talk-turn-postgres-redis-integration-test=missing", result["detail"])

    def test_rust_postgres_integration_reports_blocked_or_missing_proofs(self) -> None:
        payload = {
            "status": "fail",
            "ok": False,
            "requiredProofs": [
                {
                    "name": "postgres-schema-application",
                    "status": "blocked",
                    "reason": "Postgres/Redis services were not reachable",
                }
            ],
        }

        result = self._check_rust_postgres_integration(payload)

        self.assertEqual(result["status"], "fail")
        self.assertIn("missingProofs", result["detail"])
        self.assertIn("failedProofs", result["detail"])
        self.assertIn("Postgres/Redis services were not reachable", result["detail"])

    def _check_http_probe(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "self-hosted-http-probe.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_http_probe(str(path))

    def _http_route_observations(self) -> list[dict[str, object]]:
        routes = [
            ("app-compatible-health", "GET", "/s/turbo/v1/health", 200),
            ("app-compatible-runtime-config", "GET", "/s/turbo/v1/config", 200),
            ("app-compatible-auth-session", "POST", "/s/turbo/v1/auth/session", 200),
            ("app-compatible-device-register", "POST", "/s/turbo/v1/devices/register", 200),
            ("app-compatible-presence-keepalive", "POST", "/s/turbo/v1/presence/keepalive", 200),
            ("app-compatible-telemetry-events", "POST", "/s/turbo/v1/telemetry/events", 200),
            ("app-compatible-user-lookup", "GET", "/s/turbo/v1/users/by-handle/%40blake", 200),
            ("app-compatible-user-presence", "GET", "/s/turbo/v1/users/by-handle/%40blake/presence", 200),
            ("app-compatible-identity-resolve", "POST", "/s/turbo/v1/identities/resolve", 200),
            ("app-compatible-direct-channel", "POST", "/s/turbo/v1/channels/direct", 200),
            ("app-compatible-channel-join-self", "POST", "/s/turbo/v1/channels/direct-user-avery-user-blake/join", 200),
            ("app-compatible-channel-join-peer", "POST", "/s/turbo/v1/channels/direct-user-avery-user-blake/join", 200),
            ("app-compatible-channel-state", "GET", "/s/turbo/v1/channels/direct-user-avery-user-blake/state/device-a", 200),
            ("app-compatible-channel-readiness", "GET", "/s/turbo/v1/channels/direct-user-avery-user-blake/readiness/device-a", 200),
            (
                "app-compatible-receiver-audio-readiness",
                "POST",
                "/s/turbo/v1/channels/direct-user-avery-user-blake/receiver-audio-readiness",
                200,
            ),
            ("app-compatible-beeps-incoming", "GET", "/s/turbo/v1/beeps/incoming", 200),
            ("app-compatible-beeps-outgoing", "GET", "/s/turbo/v1/beeps/outgoing", 200),
            ("native-request-talk-turn", "POST", "/v1/conversations/conversation-1/talk-turns/request", 200),
            (
                "prefixed-native-request-talk-turn",
                "POST",
                "/s/turbo/v1/conversations/conversation-prefixed/talk-turns/request",
                200,
            ),
            ("native-renew-talk-turn", "POST", "/v1/conversations/conversation-1/talk-turns/renew", 200),
            ("native-release-talk-turn", "POST", "/v1/conversations/conversation-1/talk-turns/release", 200),
            ("legacy-begin-transmit", "POST", "/v1/channels/conversation-1/begin-transmit", 200),
            ("legacy-renew-transmit", "POST", "/v1/channels/conversation-1/renew-transmit", 200),
            ("legacy-end-transmit", "POST", "/v1/channels/conversation-1/end-transmit", 200),
            ("mismatched-conversation-rejected", "POST", "/v1/conversations/other/talk-turns/request", 400),
        ]
        return [
            {
                "kind": kind,
                "method": method,
                "path": path,
                "status_code": status_code,
                "expected_status_code": status_code,
                "ok": True,
                "semantic": f"{kind} checked",
            }
            for kind, method, path, status_code in routes
        ]

    def _check_kernel_corpus(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "kernel-corpus.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_kernel_corpus(str(path))

    def _kernel_case(
        self, case_id: str, kind: str, decision_kind: str
    ) -> dict[str, object]:
        decision: dict[str, object] = {
            "kind": decision_kind,
            "audit": {
                "kernelVersion": {"value": "kernel-contract-v1"},
                "policyVersion": {"value": "policy-v1"},
                "conversationSeq": {"value": 1},
                "snapshotHash": "snapshot-hash",
                "commandHash": "command-hash",
                "decisionHash": "decision-hash",
            },
        }
        if decision_kind == "granted":
            post_commit_kind = (
                "wake-target-device"
                if case_id == "wake-capable-target-device-grants"
                else "notify-talk-turn-granted"
            )
            decision.update(
                {
                    "grant": {"talkTurnEpoch": {"value": 1}},
                    "effectPlan": {
                        "transactionEffects": [{"kind": "record-talk-turn"}],
                        "postCommitEffects": [{"kind": post_commit_kind}],
                    },
                }
            )
        else:
            decision["reason"] = "expected-denial"
        return {
            "id": case_id,
            "kind": kind,
            "command": {"kind": kind},
            "snapshot": {"conversationId": {"value": "conversation-1"}},
            "policy": {"policyVersion": {"value": "policy-v1"}},
            "expectedDecision": decision,
        }

    def _check_websocket_probe(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "self-hosted-websocket-probe.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_websocket_probe(str(path))

    def _check_runtime_control_probe(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "runtime-control-probe.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_runtime_control_probe(str(path))

    def _runtime_control_probe_payload(self) -> dict[str, object]:
        return {
            "status": "ok",
            "ok": True,
            "checks": [
                self._runtime_control_check("runtime-quic-control"),
                self._runtime_control_check("runtime-tls-control"),
                self._runtime_control_check("persistent-control-stream"),
                self._runtime_control_check("runtime-http-bootstrap-recovery"),
                self._runtime_control_check("runtime-websocket-retired-by-default"),
            ],
        }

    def _runtime_control_check(self, name: str) -> dict[str, object]:
        return {
            "name": name,
            "ok": True,
            "exitCode": 0,
            "command": ["cargo", "test", name],
        }

    def _websocket_observations(self) -> list[dict[str, object]]:
        observations = [
            ("in-memory", "connect-source"),
            ("in-memory", "connect-target-initial"),
            ("in-memory", "route-initial-direct-quic-offer"),
            ("in-memory", "disconnect-target-initial"),
            ("in-memory", "connect-target-replacement"),
            ("in-memory", "reject-stale-target"),
            ("in-memory", "route-reconnected-direct-quic-offer"),
            ("network", "connect-source"),
            ("network", "connect-target-initial"),
            ("network", "route-initial-signal"),
            ("network", "connect-target-replacement"),
            ("network", "reject-stale-target"),
            ("network", "route-reconnected-signal"),
            ("app-compatible-cluster", "cluster-handshake"),
            ("app-compatible-cluster", "cluster-owner-routed-signal"),
            ("app-compatible-cluster", "authorization-facts-recorded"),
        ]
        return [
            {
                "mode": mode,
                "event": event,
                "ok": True,
                "detail": f"{mode}.{event} checked",
            }
            for mode, event in observations
        ]

    def _check_fuzz_artifact(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "rust-runtime-fuzz.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_fuzz_artifact(
                "rust-runtime-fuzz",
                "Rust runtime deterministic fuzz gate",
                str(path),
                expected_gate="rust-runtime-fuzz",
                min_requested_count=16,
                expected_check_prefixes=["rust-runtime iteration "],
            )

    def _check_rust_runtime_fuzz(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "rust-runtime-fuzz.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_rust_runtime_fuzz(str(path))

    def _check_reliability_fuzz(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "reliability-fuzz.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return (
                self_hosted_cutover_readiness
                .check_reliability_fuzz_self_hosted_overnight(str(path))
            )

    def _rust_runtime_fuzz_payload(self) -> dict[str, object]:
        return {
            "status": "ok",
            "gate": "rust-runtime-fuzz",
            "requested_count": 16,
            "seed": 123,
            "checks": [f"rust-runtime iteration {index}" for index in range(16)],
            "observations": [
                self._runtime_fuzz_observation(index, kind)
                for index in range(16)
                for kind in [
                    "runtime-effect-plan-interpreter",
                    "runtime-talk-turn-actor-exclusivity",
                    "runtime-owner-routing",
                    "runtime-websocket-cluster-authority",
                    "runtime-quic-payload-boundary",
                ]
            ],
        }

    def _runtime_fuzz_observation(self, iteration: int, kind: str) -> dict[str, object]:
        return {
            "kind": kind,
            "iteration": iteration,
            "verdict": "passed",
            "cloud_route": "not-applicable",
            "self_hosted_route": "rust-runtime-internal",
            "cloud_outcome": "not-applicable",
            "self_hosted_outcome": "boundary passed",
        }

    def _reliability_fuzz_payload(self) -> dict[str, object]:
        return {
            "status": "ok",
            "gate": "reliability-fuzz-self-hosted-overnight",
            "requested_count": 2,
            "seed": 123,
            "checks": [
                *[f"rust-runtime iteration {index}" for index in range(2)],
                *[f"self-hosted scenario iteration {index}" for index in range(2)],
                *[f"shadow comparison iteration {index}" for index in range(2)],
            ],
            "observations": [
                *[
                    self._runtime_fuzz_observation(index, kind)
                    for index in range(2)
                    for kind in [
                        "runtime-effect-plan-interpreter",
                        "runtime-talk-turn-actor-exclusivity",
                        "runtime-owner-routing",
                        "runtime-websocket-cluster-authority",
                        "runtime-quic-payload-boundary",
                    ]
                ],
                *[
                    self._shadow_observation(index, "divergent")
                    for index in range(2)
                ],
            ],
        }

    def _check_shadow_backend_fuzz(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "shadow-backend-fuzz.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_shadow_backend_fuzz(str(path))

    def _check_self_hosted_scenario_fuzz(
        self, payload: dict[str, object]
    ) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "self-hosted-scenario-fuzz.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_self_hosted_scenario_fuzz(
                str(path)
            )

    def _self_hosted_scenario_fuzz_payload(self) -> dict[str, object]:
        return {
            "status": "ok",
            "ok": True,
            "schemaVersion": 1,
            "gate": "self-hosted-scenario-fuzz-local",
            "substrate": "production-runtime-postgres-redis",
            "requested_count": 3,
            "seed": 123,
            "checks": [
                *[f"self-hosted scenario iteration {index}" for index in range(3)],
                *[f"production-runtime scenario iteration {index}" for index in range(3)],
            ],
            "steps": [
                {"name": "self-hosted-preflight", "ok": True, "exitCode": 0},
                {"name": "compose-up", "ok": True, "exitCode": 0},
                {"name": "service-readiness", "ok": True},
                {"name": "redis-readiness", "ok": True},
                {"name": "postgres-schema-application", "ok": True, "exitCode": 0},
                {
                    "name": "runtime-health",
                    "ok": True,
                    "baseUrl": "http://127.0.0.1:18091/s/turbo",
                },
                *[self._production_runtime_scenario(index) for index in range(3)],
            ],
        }

    def _production_runtime_scenario(self, index: int) -> dict[str, object]:
        conversation_id = f"production-conversation-{index}"
        return {
            "name": f"production-runtime-scenario-{index}",
            "ok": True,
            "conversationId": conversation_id,
            "request": {
                "_httpStatus": 200,
                "conversationId": conversation_id,
                "status": "granted",
                "requestingParticipantId": "participant-a",
                "requestingDeviceId": "device-a",
                "targetParticipantId": "participant-b",
                "targetDeviceId": "device-b",
                "talkTurnEpoch": 1,
            },
            "renew": {
                "_httpStatus": 200,
                "conversationId": conversation_id,
                "status": "renewed",
                "talkTurnEpoch": 1,
            },
            "release": {
                "_httpStatus": 200,
                "conversationId": conversation_id,
                "status": "released",
                "talkTurnEpoch": 1,
            },
        }

    def _shadow_observation(self, iteration: int, verdict: str) -> dict[str, object]:
        return {
            "kind": "shadow-begin-transmit-vs-request-talk-turn",
            "iteration": iteration,
            "verdict": verdict,
            "cloud_route": "/v1/channels/{channelId}/begin-transmit",
            "self_hosted_route": "/v1/conversations/{conversationId}/talk-turns/request",
            "cloud_outcome": "granted conversation=conversation targetDevice=device epoch=1",
            "self_hosted_outcome": "granted conversation=conversation targetDevice=device epoch=1",
        }

    def _check_self_hosted_preflight(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "self-hosted-preflight.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_self_hosted_preflight(str(path))

    def _check_model_artifact(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "protocol-model-checks.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_model_artifact(str(path))

    def _simulator_scenario_stdout(self) -> str:
        count = self_hosted_cutover_readiness.checked_in_simulator_scenario_count()
        return "\n".join(
            line
            for index in range(1, count + 1)
            for line in [
                f"Running simulator scenario {index}/{count}: scenario-{index}",
                f"Simulator scenario finished: scenario-{index}",
                "** TEST SUCCEEDED **",
            ]
        )

    def _check_physical_boundaries(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "physical-device-boundaries.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_physical_device_boundaries(str(path))

    def _check_simulator_suite(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "simulator-self-hosted-suite.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_simulator_self_hosted_suite(str(path))

    def _check_rust_postgres_integration(self, payload: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "rust-postgres-integration.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return self_hosted_cutover_readiness.check_rust_postgres_integration(str(path))


if __name__ == "__main__":
    unittest.main()
