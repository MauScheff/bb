#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_ARTIFACTS = {
    "kernelCorpus": "/tmp/turbo-kernel-corpus.json",
    "rustRuntimeFuzz": "/tmp/turbo-rust-runtime-fuzz/report.json",
    "selfHostedPreflight": "/tmp/turbo-self-hosted-preflight.json",
    "selfHostedHttpProbe": "/tmp/turbo-self-hosted-http-probe.json",
    "selfHostedWebSocketProbe": "/tmp/turbo-self-hosted-websocket-probe.json",
    "selfHostedScenarioFuzz": "/tmp/turbo-self-hosted-fuzz/report.json",
    "selfHostedReliabilityFuzz": "/tmp/turbo-self-hosted-fuzz/overnight-report.json",
    "shadowBackendFuzz": "/tmp/turbo-shadow-backend-fuzz/report.json",
    "talkTurnActorModel": "/tmp/turbo-protocol-talk-turn-actor-model-check/protocol-model-checks.json",
    "rustPostgresIntegration": "/tmp/turbo-rust-runtime-integration.json",
    "simulatorSelfHostedSuite": "/tmp/turbo-simulator-self-hosted-suite.json",
    "physicalDeviceBoundaries": "/tmp/turbo-physical-device-boundaries.json",
    "physicalDeviceBoundaryStatus": "/tmp/turbo-physical-device-boundary-status-current.json",
    "physicalDeviceBoundaryFinalize": "/tmp/turbo-physical-device-boundary-finalize.json",
}
DEFAULT_CURRENT_OUTPUT = "/tmp/turbo-self-hosted-cutover-readiness-current.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize self-hosted runtime cutover readiness evidence."
    )
    parser.add_argument(
        "--output",
        default="/tmp/turbo-self-hosted-cutover-readiness.json",
        help="JSON readiness artifact path.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    evidence = [
        check_kernel_corpus(DEFAULT_ARTIFACTS["kernelCorpus"]),
        check_rust_runtime_fuzz(DEFAULT_ARTIFACTS["rustRuntimeFuzz"]),
        check_self_hosted_preflight(DEFAULT_ARTIFACTS["selfHostedPreflight"]),
        check_http_probe(DEFAULT_ARTIFACTS["selfHostedHttpProbe"]),
        check_websocket_probe(DEFAULT_ARTIFACTS["selfHostedWebSocketProbe"]),
        check_self_hosted_scenario_fuzz(DEFAULT_ARTIFACTS["selfHostedScenarioFuzz"]),
        check_reliability_fuzz_self_hosted_overnight(
            DEFAULT_ARTIFACTS["selfHostedReliabilityFuzz"]
        ),
        check_shadow_backend_fuzz(DEFAULT_ARTIFACTS["shadowBackendFuzz"]),
        check_model_artifact(DEFAULT_ARTIFACTS["talkTurnActorModel"]),
        check_rust_postgres_integration(DEFAULT_ARTIFACTS["rustPostgresIntegration"]),
        check_simulator_self_hosted_suite(DEFAULT_ARTIFACTS["simulatorSelfHostedSuite"]),
        check_physical_device_boundaries(DEFAULT_ARTIFACTS["physicalDeviceBoundaries"]),
    ]

    summary = build_readiness_summary(evidence)
    output = Path(args.output)
    write_readiness_outputs(summary, output)
    print(f"self-hosted cutover readiness: {summary['status']}")
    print(f"self-hosted cutover readiness artifact: {output}")
    return 0 if summary["ready"] else 1


def write_readiness_outputs(
    summary: dict[str, Any],
    output: Path,
    current_output: Path = Path(DEFAULT_CURRENT_OUTPUT),
) -> None:
    payload = json.dumps(summary, indent=2, sort_keys=True) + "\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(payload, encoding="utf-8")
    if current_output != output:
        current_output.parent.mkdir(parents=True, exist_ok=True)
        current_output.write_text(payload, encoding="utf-8")


def build_readiness_summary(evidence: list[dict[str, Any]]) -> dict[str, Any]:
    ready = all(item["status"] == "pass" for item in evidence)
    return {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "ready": ready,
        "ok": ready,
        "status": "ready" if ready else "not-ready",
        "evidence": evidence,
        "blockingEvidence": [
            item
            for item in evidence
            if item.get("requiredForCutover") is True and item["status"] != "pass"
        ],
    }


KERNEL_CORPUS_CASE_REQUIREMENTS: dict[str, dict[str, Any]] = {
    "valid-request-talk-turn-grant": {
        "kind": "request-talk-turn",
        "decision": "granted",
        "postCommitEffect": "notify-talk-turn-granted",
    },
    "duplicate-request-denies-while-current-talk-turn-active": {
        "kind": "request-talk-turn",
        "decision": "denied",
    },
    "stale-release-talk-turn-denies": {
        "kind": "release-talk-turn",
        "decision": "denied",
    },
    "expired-current-talk-turn-can-be-replaced": {
        "kind": "request-talk-turn",
        "decision": "granted",
        "postCommitEffect": "notify-talk-turn-granted",
    },
    "ready-target-participant-grants": {
        "kind": "request-talk-turn",
        "decision": "granted",
        "postCommitEffect": "notify-talk-turn-granted",
    },
    "not-ready-target-participant-denies": {
        "kind": "request-talk-turn",
        "decision": "denied",
    },
    "wake-capable-target-device-grants": {
        "kind": "request-talk-turn",
        "decision": "granted",
        "postCommitEffect": "wake-target-device",
    },
    "stale-device-readiness-denies": {
        "kind": "request-talk-turn",
        "decision": "denied",
    },
    "missing-participant-denies": {
        "kind": "request-talk-turn",
        "decision": "denied",
    },
    "malformed-snapshot-invalidates": {
        "kind": "request-talk-turn",
        "decision": "invalid-snapshot",
    },
}


def kernel_case_has_effect(
    effect_plan: dict[str, Any], phase: str, effect_kind: str
) -> bool:
    effects = effect_plan.get(phase)
    if not isinstance(effects, list):
        return False
    return any(
        isinstance(effect, dict) and effect.get("kind") == effect_kind
        for effect in effects
    )


def check_kernel_corpus(path: str) -> dict[str, Any]:
    payload = read_json(path)
    if payload is None:
        return missing_required(
            "kernel-golden-corpus",
            "Kernel golden/corpus fixture artifact",
            f"Run `just kernel-corpus-json {path}`.",
            path,
        )
    cases = payload.get("cases")
    required_case_ids = set(KERNEL_CORPUS_CASE_REQUIREMENTS.keys())
    failures = []
    if not isinstance(cases, list):
        failures.append("cases=missing")
        observed_case_ids = set()
    else:
        observed_case_ids = {
            case.get("id")
            for case in cases
            if isinstance(case, dict) and isinstance(case.get("id"), str)
        }
        duplicate_case_ids = sorted(
            {
                case_id
                for case_id in observed_case_ids
                if sum(
                    1
                    for case in cases
                    if isinstance(case, dict) and case.get("id") == case_id
                )
                > 1
            }
        )
        if duplicate_case_ids:
            failures.append(f"duplicateCases={duplicate_case_ids!r}")
        malformed_cases = [
            case.get("id", "<unknown>")
            for case in cases
            if not (
                isinstance(case, dict)
                and isinstance(case.get("id"), str)
                and case.get("kind") in {"request-talk-turn", "release-talk-turn"}
                and isinstance(case.get("command"), dict)
                and isinstance(case.get("snapshot"), dict)
                and isinstance(case.get("policy"), dict)
                and isinstance(case.get("expectedDecision"), dict)
            )
        ]
        if malformed_cases:
            failures.append(f"malformedCases={malformed_cases[:4]!r}")
        for case in cases:
            if not isinstance(case, dict):
                continue
            case_id = case.get("id")
            if not isinstance(case_id, str):
                continue
            requirement = KERNEL_CORPUS_CASE_REQUIREMENTS.get(case_id)
            if requirement is None:
                continue
            expected_kind = requirement["kind"]
            expected_decision = requirement["decision"]
            command = case.get("command")
            policy = case.get("policy")
            decision = case.get("expectedDecision")
            if case.get("kind") != expected_kind:
                failures.append(f"{case_id}:kind={case.get('kind')!r}")
            if not isinstance(command, dict) or command.get("kind") != expected_kind:
                command_kind = command.get("kind") if isinstance(command, dict) else None
                failures.append(f"{case_id}:command.kind={command_kind!r}")
            if not isinstance(policy, dict) or not isinstance(
                policy.get("policyVersion"), dict
            ):
                failures.append(f"{case_id}:policyVersion=missing")
            if not isinstance(decision, dict):
                continue
            if decision.get("kind") != expected_decision:
                failures.append(f"{case_id}:decision={decision.get('kind')!r}")
            audit = decision.get("audit")
            if not isinstance(audit, dict):
                failures.append(f"{case_id}:audit=missing")
            else:
                for key in [
                    "kernelVersion",
                    "policyVersion",
                    "conversationSeq",
                    "snapshotHash",
                    "commandHash",
                    "decisionHash",
                ]:
                    if key not in audit:
                        failures.append(f"{case_id}:audit.{key}=missing")
            if expected_decision == "granted":
                effect_plan = decision.get("effectPlan")
                if not isinstance(decision.get("grant"), dict):
                    failures.append(f"{case_id}:grant=missing")
                if not isinstance(effect_plan, dict):
                    failures.append(f"{case_id}:effectPlan=missing")
                elif not kernel_case_has_effect(
                    effect_plan, "transactionEffects", "record-talk-turn"
                ):
                    failures.append(f"{case_id}:record-talk-turn=missing")
                elif not kernel_case_has_effect(
                    effect_plan,
                    "postCommitEffects",
                    str(requirement["postCommitEffect"]),
                ):
                    failures.append(
                        f"{case_id}:{requirement['postCommitEffect']}=missing"
                    )
            elif (
                expected_decision in {"denied", "invalid-snapshot"}
                and decision.get("reason") is None
            ):
                failures.append(f"{case_id}:reason=missing")
    missing_case_ids = sorted(required_case_ids - observed_case_ids)
    if missing_case_ids:
        failures.append(f"missingCases={missing_case_ids!r}")
    ok = not failures
    detail = f"{len(cases) if isinstance(cases, list) else 0} cases observed"
    if failures:
        detail += f"; failures={failures!r}"
    return evidence(
        "kernel-golden-corpus",
        "Kernel golden/corpus fixture artifact",
        "pass" if ok else "fail",
        path,
        detail,
    )


def check_status_artifact(
    name: str,
    description: str,
    path: str,
    *,
    required_for_cutover: bool = True,
    remediation: str | None = None,
) -> dict[str, Any]:
    payload = read_json(path)
    if payload is None:
        return missing_required(
            name,
            description,
            remediation or f"Run the recipe that writes {path}.",
            path,
            required_for_cutover=required_for_cutover,
        )
    ok = payload.get("ok") is True or payload.get("status") in {"ok", "pass"}
    result = evidence(
        name,
        description,
        "pass" if ok else "fail",
        path,
        status_artifact_detail(payload),
        required_for_cutover=required_for_cutover,
    )
    if not ok and remediation:
        result["remediation"] = remediation
    return result


def check_self_hosted_preflight(path: str) -> dict[str, Any]:
    payload = read_json(path)
    remediation = (
        "Start Docker/Compose or provide reachable Postgres on 127.0.0.1:55432 "
        "and Redis on 127.0.0.1:56379, then rerun `just self-hosted-preflight`."
    )
    if payload is None:
        return missing_required(
            "self-hosted-preflight",
            "Docker/Compose/Postgres/Redis readiness",
            remediation,
            path,
        )
    ok = payload.get("ok") is True and payload.get("status") == "pass"
    substrate = payload.get("substrate")
    docker_ready = payload.get("dockerReady")
    existing_services_ready = payload.get("existingServicesReady")
    steps = payload.get("steps")
    step_by_name = {
        str(step.get("name") or ""): step
        for step in steps
        if isinstance(step, dict)
    } if isinstance(steps, list) else {}
    failures: list[str] = []
    if not ok:
        failures.append(f"status={payload.get('status')!r} ok={payload.get('ok')!r}")
    if substrate not in {"docker-compose", "existing-services"}:
        failures.append(f"substrate={substrate!r}")
    if substrate == "docker-compose":
        for step_name in ["docker-cli", "compose-file", "compose-config", "docker-daemon"]:
            step = step_by_name.get(step_name)
            if not isinstance(step, dict):
                failures.append(f"{step_name}=missing")
            elif step.get("ok") is not True:
                failures.append(f"{step_name}=failed")
        if docker_ready is not True:
            failures.append(f"dockerReady={docker_ready!r}")
    if substrate == "existing-services":
        for step_name in ["postgres-tcp", "redis-tcp", "postgres-protocol", "redis-protocol"]:
            step = step_by_name.get(step_name)
            if not isinstance(step, dict):
                failures.append(f"{step_name}=missing")
            elif step.get("ok") is not True:
                failures.append(f"{step_name}=failed")
        if existing_services_ready is not True:
            failures.append(f"existingServicesReady={existing_services_ready!r}")
    if docker_ready is not True and existing_services_ready is not True:
        failures.append("no-ready-substrate")
    detail = (
        f"artifact status={payload.get('status')!r} ok={payload.get('ok')!r} "
        f"substrate={substrate!r} dockerReady={docker_ready!r} "
        f"existingServicesReady={existing_services_ready!r}"
    )
    failed_steps = [
        step.get("name")
        for step in steps
        if isinstance(steps, list)
        and isinstance(step, dict)
        and step.get("ok") is not True
        and step.get("name")
    ] if isinstance(steps, list) else []
    if failures and failed_steps:
        detail += f" failedSteps={failed_steps[:4]!r}"
    if failures:
        detail += f" failures={failures!r}"
    result = evidence(
        "self-hosted-preflight",
        "Docker/Compose/Postgres/Redis readiness",
        "fail" if failures else "pass",
        path,
        detail,
    )
    if failures:
        result["remediation"] = remediation
    return result


def check_fuzz_artifact(
    name: str,
    description: str,
    path: str,
    *,
    expected_gate: str,
    min_requested_count: int,
    expected_check_prefixes: list[str],
    required_for_cutover: bool = True,
) -> dict[str, Any]:
    payload = read_json(path)
    if payload is None:
        return missing_required(
            name,
            description,
            f"Run the recipe that writes {path}.",
            path,
            required_for_cutover=required_for_cutover,
        )
    checks = payload.get("checks")
    requested_count = payload.get("requested_count")
    failures = []
    if payload.get("status") != "ok":
        failures.append(f"status={payload.get('status')!r}")
    if payload.get("gate") != expected_gate:
        failures.append(f"gate={payload.get('gate')!r}")
    if not isinstance(requested_count, int) or requested_count < min_requested_count:
        failures.append(f"requested_count={requested_count!r}")
    if not isinstance(checks, list):
        failures.append("checks=missing")
    else:
        if len({str(check) for check in checks if isinstance(check, str)}) != len(checks):
            failures.append("checks=duplicates")
        for prefix in expected_check_prefixes:
            expected_count = (
                max(requested_count, min_requested_count)
                if isinstance(requested_count, int)
                else min_requested_count
            )
            observed_iterations = fuzz_iterations_for_prefix(checks, prefix)
            observed_count = len(observed_iterations)
            if observed_count < expected_count:
                failures.append(f"{prefix.strip()} checks={observed_count}")
            expected_iterations = set(range(expected_count))
            if observed_iterations != expected_iterations:
                missing = sorted(expected_iterations - observed_iterations)
                extra = sorted(observed_iterations - expected_iterations)
                if missing:
                    failures.append(f"{prefix.strip()} missingIterations={missing[:8]!r}")
                if extra:
                    failures.append(f"{prefix.strip()} extraIterations={extra[:8]!r}")
    ok = not failures
    detail = (
        f"gate={payload.get('gate')!r} requestedCount={requested_count!r} "
        f"checkCount={len(checks) if isinstance(checks, list) else 0}"
    )
    if failures:
        detail += f"; failures={failures!r}"
    return evidence(
        name,
        description,
        "pass" if ok else "fail",
        path,
        detail,
        required_for_cutover=required_for_cutover,
    )


RUST_RUNTIME_FUZZ_OBSERVATION_KINDS = {
    "runtime-effect-plan-interpreter",
    "runtime-talk-turn-actor-exclusivity",
    "runtime-owner-routing",
    "runtime-websocket-cluster-authority",
    "runtime-quic-payload-boundary",
}


def check_rust_runtime_fuzz(path: str) -> dict[str, Any]:
    result = check_fuzz_artifact(
        "rust-runtime-fuzz",
        "Rust runtime deterministic fuzz gate",
        path,
        expected_gate="rust-runtime-fuzz",
        min_requested_count=16,
        expected_check_prefixes=["rust-runtime iteration "],
    )
    payload = read_json(path)
    if payload is None or result["status"] != "pass":
        return result

    requested_count = payload.get("requested_count")
    expected_count = (
        max(requested_count, 16) if isinstance(requested_count, int) else 16
    )
    observations = payload.get("observations")
    failures: list[str] = []
    if not isinstance(observations, list):
        failures.append("observations=missing")
        observed: dict[int, set[str]] = {}
    else:
        observed = {}
        for observation in observations:
            if not isinstance(observation, dict):
                failures.append("observation=malformed")
                continue
            iteration = observation.get("iteration")
            kind = observation.get("kind")
            if not isinstance(iteration, int):
                failures.append(f"observation.iteration={iteration!r}")
                continue
            if kind not in RUST_RUNTIME_FUZZ_OBSERVATION_KINDS:
                failures.append(f"observation.kind={kind!r}")
                continue
            if observation.get("verdict") != "passed":
                failures.append(f"{kind}:verdict={observation.get('verdict')!r}")
            outcome = observation.get("self_hosted_outcome")
            if not isinstance(outcome, str) or not outcome:
                failures.append(f"{kind}:outcome=missing")
            observed.setdefault(iteration, set()).add(str(kind))
    for iteration in range(expected_count):
        missing_kinds = sorted(
            RUST_RUNTIME_FUZZ_OBSERVATION_KINDS - observed.get(iteration, set())
        )
        if missing_kinds:
            failures.append(
                f"iteration {iteration} missingObservations={missing_kinds!r}"
            )
    extra_iterations = sorted(set(observed) - set(range(expected_count)))
    if extra_iterations:
        failures.append(f"extraObservationIterations={extra_iterations[:8]!r}")

    if not failures:
        result["detail"] += (
            f" observations={len(observations) if isinstance(observations, list) else 0}"
            f" observationKinds={sorted(RUST_RUNTIME_FUZZ_OBSERVATION_KINDS)!r}"
        )
        return result
    result["status"] = "fail"
    result["detail"] += f"; observationFailures={failures!r}"
    return result


def check_shadow_backend_fuzz(path: str) -> dict[str, Any]:
    result = check_fuzz_artifact(
        "shadow-backend-fuzz",
        "Cloud-vs-self-hosted normalized behavior fuzz",
        path,
        expected_gate="shadow-backend-fuzz",
        min_requested_count=8,
        expected_check_prefixes=["shadow comparison iteration "],
    )
    payload = read_json(path)
    if payload is None or result["status"] != "pass":
        return result

    requested_count = payload.get("requested_count")
    expected_count = requested_count if isinstance(requested_count, int) else 8
    observations = payload.get("observations")
    failures: list[str] = []
    if not isinstance(observations, list):
        failures.append("observations=missing")
        observed_iterations: set[int] = set()
        verdicts: set[str] = set()
    else:
        observed_iterations = {
            observation.get("iteration")
            for observation in observations
            if isinstance(observation, dict) and isinstance(observation.get("iteration"), int)
        }
        verdicts = {
            str(observation.get("verdict"))
            for observation in observations
            if isinstance(observation, dict) and isinstance(observation.get("verdict"), str)
        }
        if len(observations) < expected_count:
            failures.append(f"observations={len(observations)}")
        for observation in observations:
            if not isinstance(observation, dict):
                failures.append("observation=malformed")
                continue
            iteration = observation.get("iteration")
            if not isinstance(iteration, int):
                failures.append(f"observation.iteration={iteration!r}")
            if observation.get("kind") != "shadow-begin-transmit-vs-request-talk-turn":
                failures.append(f"observation.kind={observation.get('kind')!r}")
            if observation.get("verdict") not in {"equivalent", "divergent"}:
                failures.append(f"observation.verdict={observation.get('verdict')!r}")
            if observation.get("cloud_route") != "/v1/channels/{channelId}/begin-transmit":
                failures.append(f"cloud_route={observation.get('cloud_route')!r}")
            if (
                observation.get("self_hosted_route")
                != "/v1/conversations/{conversationId}/talk-turns/request"
            ):
                failures.append(
                    f"self_hosted_route={observation.get('self_hosted_route')!r}"
                )
            for key in ["cloud_outcome", "self_hosted_outcome"]:
                value = observation.get(key)
                if not isinstance(value, str) or not value:
                    failures.append(f"{key}=missing")
    expected_iterations = set(range(expected_count))
    if observed_iterations != expected_iterations:
        missing = sorted(expected_iterations - observed_iterations)
        extra = sorted(observed_iterations - expected_iterations)
        if missing:
            failures.append(f"observationMissingIterations={missing[:8]!r}")
        if extra:
            failures.append(f"observationExtraIterations={extra[:8]!r}")
    if "equivalent" not in verdicts:
        failures.append("equivalentVerdict=missing")
    if "divergent" not in verdicts:
        failures.append("divergentVerdict=missing")

    if not failures:
        result["detail"] += (
            f" observations={len(observations) if isinstance(observations, list) else 0}"
            f" verdicts={sorted(verdicts)!r}"
        )
        return result
    result["status"] = "fail"
    result["detail"] += f"; observationFailures={failures!r}"
    return result


def check_reliability_fuzz_self_hosted_overnight(path: str) -> dict[str, Any]:
    result = check_fuzz_artifact(
        "reliability-fuzz-self-hosted-overnight",
        "Combined deterministic self-hosted reliability sweep",
        path,
        expected_gate="reliability-fuzz-self-hosted-overnight",
        min_requested_count=2,
        expected_check_prefixes=[
            "rust-runtime iteration ",
            "self-hosted scenario iteration ",
            "shadow comparison iteration ",
        ],
    )
    payload = read_json(path)
    if payload is None or result["status"] != "pass":
        return result

    requested_count = payload.get("requested_count")
    expected_count = (
        max(requested_count, 2) if isinstance(requested_count, int) else 2
    )
    observations = payload.get("observations")
    failures: list[str] = []
    runtime_observed: dict[int, set[str]] = {}
    shadow_observed: dict[int, set[str]] = {}
    if not isinstance(observations, list):
        failures.append("observations=missing")
    else:
        for observation in observations:
            if not isinstance(observation, dict):
                failures.append("observation=malformed")
                continue
            iteration = observation.get("iteration")
            kind = observation.get("kind")
            if not isinstance(iteration, int):
                failures.append(f"observation.iteration={iteration!r}")
                continue
            if kind in RUST_RUNTIME_FUZZ_OBSERVATION_KINDS:
                if observation.get("verdict") != "passed":
                    failures.append(f"{kind}:verdict={observation.get('verdict')!r}")
                outcome = observation.get("self_hosted_outcome")
                if not isinstance(outcome, str) or not outcome:
                    failures.append(f"{kind}:outcome=missing")
                runtime_observed.setdefault(iteration, set()).add(str(kind))
            elif kind == "shadow-begin-transmit-vs-request-talk-turn":
                if observation.get("verdict") not in {"equivalent", "divergent"}:
                    failures.append(
                        f"shadow.verdict={observation.get('verdict')!r}"
                    )
                if (
                    observation.get("cloud_route")
                    != "/v1/channels/{channelId}/begin-transmit"
                ):
                    failures.append(f"cloud_route={observation.get('cloud_route')!r}")
                if (
                    observation.get("self_hosted_route")
                    != "/v1/conversations/{conversationId}/talk-turns/request"
                ):
                    failures.append(
                        f"self_hosted_route={observation.get('self_hosted_route')!r}"
                    )
                for key in ["cloud_outcome", "self_hosted_outcome"]:
                    value = observation.get(key)
                    if not isinstance(value, str) or not value:
                        failures.append(f"{key}=missing")
                shadow_observed.setdefault(iteration, set()).add(str(observation.get("verdict")))
            else:
                failures.append(f"observation.kind={kind!r}")
    expected_iterations = set(range(expected_count))
    for iteration in range(expected_count):
        missing_runtime = sorted(
            RUST_RUNTIME_FUZZ_OBSERVATION_KINDS
            - runtime_observed.get(iteration, set())
        )
        if missing_runtime:
            failures.append(
                f"runtime iteration {iteration} missingObservations={missing_runtime!r}"
            )
        if iteration not in shadow_observed:
            failures.append(f"shadow iteration {iteration} observation=missing")
    extra_runtime = sorted(set(runtime_observed) - expected_iterations)
    extra_shadow = sorted(set(shadow_observed) - expected_iterations)
    if extra_runtime:
        failures.append(f"runtimeExtraObservationIterations={extra_runtime[:8]!r}")
    if extra_shadow:
        failures.append(f"shadowExtraObservationIterations={extra_shadow[:8]!r}")

    if not failures:
        result["detail"] += (
            f" observations={len(observations) if isinstance(observations, list) else 0}"
            f" runtimeObservationKinds={sorted(RUST_RUNTIME_FUZZ_OBSERVATION_KINDS)!r}"
            f" shadowObservations={sum(len(v) for v in shadow_observed.values())}"
        )
        return result
    result["status"] = "fail"
    result["detail"] += f"; observationFailures={failures!r}"
    return result


def check_self_hosted_scenario_fuzz(path: str) -> dict[str, Any]:
    result = check_fuzz_artifact(
        "self-hosted-scenario-fuzz-local",
        "Self-hosted scenario fuzz with deterministic and production-runtime coverage",
        path,
        expected_gate="self-hosted-scenario-fuzz-local",
        min_requested_count=3,
        expected_check_prefixes=[
            "self-hosted scenario iteration ",
            "production-runtime scenario iteration ",
        ],
    )
    payload = read_json(path)
    if payload is None or result["status"] != "pass":
        return result

    requested_count = payload.get("requested_count")
    expected_count = (
        max(requested_count, 3) if isinstance(requested_count, int) else 3
    )
    failures: list[str] = []
    if payload.get("ok") is not True:
        failures.append(f"ok={payload.get('ok')!r}")
    if payload.get("schemaVersion") != 1:
        failures.append(f"schemaVersion={payload.get('schemaVersion')!r}")
    if payload.get("substrate") != "production-runtime-postgres-redis":
        failures.append(f"substrate={payload.get('substrate')!r}")
    for step_name in [
        "self-hosted-preflight",
        "compose-up",
        "service-readiness",
        "redis-readiness",
        "postgres-schema-application",
        "runtime-health",
    ]:
        step = find_step(payload, step_name)
        if not isinstance(step, dict):
            failures.append(f"{step_name}=missing")
        elif step.get("ok") is not True:
            failures.append(f"{step_name}=failed")
    runtime = find_step(payload, "runtime-health")
    if isinstance(runtime, dict):
        base_url = runtime.get("baseUrl")
        if not isinstance(base_url, str) or not base_url.startswith("http://"):
            failures.append(f"runtime-health.baseUrl={base_url!r}")

    for index in range(expected_count):
        step_name = f"production-runtime-scenario-{index}"
        step = find_step(payload, step_name)
        if not isinstance(step, dict):
            failures.append(f"{step_name}=missing")
            continue
        scenario_failures = production_runtime_scenario_failures(step)
        failures.extend(f"{step_name}:{failure}" for failure in scenario_failures)

    if not failures:
        result["detail"] += (
            f" substrate={payload.get('substrate')!r}"
            f" productionScenarios={expected_count}"
        )
        return result
    result["status"] = "fail"
    result["detail"] += f"; scenarioFailures={failures!r}"
    return result


def production_runtime_scenario_failures(step: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    if step.get("ok") is not True:
        failures.append("ok=false")
    conversation_id = step.get("conversationId")
    if not isinstance(conversation_id, str) or not conversation_id:
        failures.append("conversationId=missing")
    request = step.get("request")
    renew = step.get("renew")
    release = step.get("release")
    for name, value in [("request", request), ("renew", renew), ("release", release)]:
        if not isinstance(value, dict):
            failures.append(f"{name}=missing")
    if not isinstance(request, dict):
        return failures
    talk_turn_epoch = request.get("talkTurnEpoch")
    if request.get("_httpStatus") != 200 or request.get("status") != "granted":
        failures.append("request=not-granted")
    if request.get("conversationId") != conversation_id:
        failures.append("request.conversationId=mismatch")
    if request.get("requestingParticipantId") != "participant-a":
        failures.append("requestingParticipantId=mismatch")
    if request.get("targetParticipantId") != "participant-b":
        failures.append("targetParticipantId=mismatch")
    if request.get("requestingDeviceId") != "device-a":
        failures.append("requestingDeviceId=mismatch")
    if request.get("targetDeviceId") != "device-b":
        failures.append("targetDeviceId=mismatch")
    if not isinstance(talk_turn_epoch, int):
        failures.append("talkTurnEpoch=missing")
    if isinstance(renew, dict):
        if renew.get("_httpStatus") != 200 or renew.get("status") != "renewed":
            failures.append("renew=not-renewed")
        if renew.get("conversationId") != conversation_id:
            failures.append("renew.conversationId=mismatch")
        if renew.get("talkTurnEpoch") != talk_turn_epoch:
            failures.append("renew.talkTurnEpoch=mismatch")
    if isinstance(release, dict):
        if release.get("_httpStatus") != 200 or release.get("status") != "released":
            failures.append("release=not-released")
        if release.get("conversationId") != conversation_id:
            failures.append("release.conversationId=mismatch")
        if release.get("talkTurnEpoch") != talk_turn_epoch:
            failures.append("release.talkTurnEpoch=mismatch")
    return failures


def fuzz_iterations_for_prefix(checks: list[Any], prefix: str) -> set[int]:
    iterations: set[int] = set()
    pattern = re.compile(rf"^{re.escape(prefix)}(\d+)$")
    for check in checks:
        if not isinstance(check, str):
            continue
        match = pattern.match(check)
        if match:
            iterations.add(int(match.group(1)))
    return iterations


def check_http_probe(path: str) -> dict[str, Any]:
    payload = read_json(path)
    if payload is None:
        return missing_required(
            "self-hosted-http-probe",
            "Self-hosted native and legacy HTTP probe",
            f"Run `just self-hosted-http-probe {path}`.",
            path,
        )
    required_checks = [
        "health_ok",
        "bootstrap_ok",
        "discovery_ok",
        "native_granted",
        "prefixed_native_granted",
        "native_renewed",
        "native_released",
        "legacy_transmitting",
        "legacy_renew_transmitting",
        "legacy_end_stopped",
        "bad_request_rejected",
    ]
    required_steps = [
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
    ]
    failures = []
    if payload.get("status") != "ok":
        failures.append(f"status={payload.get('status')!r}")
    failed_checks = [check for check in required_checks if payload.get(check) is not True]
    if failed_checks:
        failures.append(f"failedChecks={failed_checks!r}")
    missing_steps = missing_required_steps(payload.get("steps"), required_steps)
    if missing_steps:
        failures.append(f"missingSteps={missing_steps[:6]!r}")
    required_observations = [
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
        ("app-compatible-receiver-audio-readiness", "POST", "/s/turbo/v1/channels/direct-user-avery-user-blake/receiver-audio-readiness", 200),
        ("app-compatible-beeps-incoming", "GET", "/s/turbo/v1/beeps/incoming", 200),
        ("app-compatible-beeps-outgoing", "GET", "/s/turbo/v1/beeps/outgoing", 200),
        ("native-request-talk-turn", "POST", "/v1/conversations/conversation-1/talk-turns/request", 200),
        ("prefixed-native-request-talk-turn", "POST", "/s/turbo/v1/conversations/conversation-1/talk-turns/request", 200),
        ("native-renew-talk-turn", "POST", "/v1/conversations/conversation-1/talk-turns/renew", 200),
        ("native-release-talk-turn", "POST", "/v1/conversations/conversation-1/talk-turns/release", 200),
        ("legacy-begin-transmit", "POST", "/v1/channels/conversation-1/begin-transmit", 200),
        ("legacy-renew-transmit", "POST", "/v1/channels/conversation-1/renew-transmit", 200),
        ("legacy-end-transmit", "POST", "/v1/channels/conversation-1/end-transmit", 200),
        ("mismatched-conversation-rejected", "POST", "/v1/conversations/other/talk-turns/request", 400),
    ]
    observation_count, observation_failures = http_route_observation_failures(
        payload.get("observations"), required_observations
    )
    failures.extend(observation_failures)
    detail = (
        "health, app bootstrap, discovery, native request/renew/release, "
        "/s/turbo-prefixed native request, legacy begin/renew/end, and bad-request HTTP probes checked"
    )
    if observation_count is not None:
        detail += f"; observations={observation_count}"
    if failures:
        detail += f"; failures={failures!r}"
    return evidence(
        "self-hosted-http-probe",
        "Self-hosted native and legacy HTTP probe",
        "fail" if failures else "pass",
        path,
        detail,
    )


def check_websocket_probe(path: str) -> dict[str, Any]:
    payload = read_json(path)
    if payload is None:
        return missing_required(
            "self-hosted-websocket-probe",
            "Self-hosted websocket signaling probe",
            f"Run `just self-hosted-websocket-probe {path}`.",
            path,
        )
    required_checks = [
        "routed_initial_payload",
        "stale_connection_rejected",
        "routed_reconnected_payload",
        "real_network_routed_payload",
        "real_network_stale_connection_rejected",
        "app_compatible_handshake_ok",
        "app_compatible_cluster_owner_routed_payload",
        "app_compatible_authorization_facts_recorded",
    ]
    required_steps = [
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
    ]
    failures = []
    if payload.get("status") != "ok":
        failures.append(f"status={payload.get('status')!r}")
    failed_checks = [check for check in required_checks if payload.get(check) is not True]
    if failed_checks:
        failures.append(f"failedChecks={failed_checks!r}")
    if payload.get("reconnected_session_id") != "1":
        failures.append(f"reconnected_session_id={payload.get('reconnected_session_id')!r}")
    if payload.get("real_network_reconnected_session_id") != "1":
        failures.append(f"real_network_reconnected_session_id={payload.get('real_network_reconnected_session_id')!r}")
    missing_steps = missing_required_steps(payload.get("steps"), required_steps)
    if missing_steps:
        failures.append(f"missingSteps={missing_steps[:6]!r}")
    required_observations = [
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
    observation_count, observation_failures = websocket_observation_failures(
        payload.get("observations"), required_observations
    )
    failures.extend(observation_failures)
    detail = (
        "in-memory routing, real TCP/WebSocket routing, stale connection rejection, "
        "reconnect session freshness, app-compatible clustered handshake, owner-routed "
        "payload delivery, and authorization fact recording checked"
    )
    if observation_count is not None:
        modes = sorted(
            {
                str(observation.get("mode"))
                for observation in payload.get("observations", [])
                if isinstance(observation, dict)
            }
        )
        detail += f"; observations={observation_count} modes={modes!r}"
    if failures:
        detail += f"; failures={failures!r}"
    return evidence(
        "self-hosted-websocket-probe",
        "Self-hosted websocket signaling probe",
        "fail" if failures else "pass",
        path,
        detail,
    )


def missing_required_steps(steps: Any, required_steps: list[str]) -> list[str]:
    if not isinstance(steps, list):
        return required_steps
    observed = {str(step) for step in steps if isinstance(step, str)}
    return [step for step in required_steps if step not in observed]


def http_route_observation_failures(
    observations: Any, required_observations: list[tuple[str, str, str, int]]
) -> tuple[int | None, list[str]]:
    if not isinstance(observations, list):
        return None, ["observations=missing"]
    failures: list[str] = []
    by_kind: dict[str, dict[str, Any]] = {}
    duplicates: list[str] = []
    for observation in observations:
        if not isinstance(observation, dict):
            failures.append(f"malformedObservation={observation!r}")
            continue
        kind = observation.get("kind")
        if not isinstance(kind, str):
            failures.append(f"observationKind={kind!r}")
            continue
        if kind in by_kind:
            duplicates.append(kind)
            continue
        by_kind[kind] = observation
    if duplicates:
        failures.append(f"duplicateObservations={sorted(duplicates)!r}")
    for kind, method, path, status_code in required_observations:
        observation = by_kind.get(kind)
        if observation is None:
            failures.append(f"missingObservation={kind!r}")
            continue
        if observation.get("method") != method:
            failures.append(f"{kind}.method={observation.get('method')!r}")
        if observation.get("path") != path:
            failures.append(f"{kind}.path={observation.get('path')!r}")
        if observation.get("status_code") != status_code:
            failures.append(f"{kind}.status_code={observation.get('status_code')!r}")
        if observation.get("expected_status_code") != status_code:
            failures.append(
                f"{kind}.expected_status_code={observation.get('expected_status_code')!r}"
            )
        if observation.get("ok") is not True:
            failures.append(f"{kind}.ok={observation.get('ok')!r}")
        semantic = observation.get("semantic")
        if not isinstance(semantic, str) or not semantic:
            failures.append(f"{kind}.semantic=missing")
    return len(observations), failures


def websocket_observation_failures(
    observations: Any, required_observations: list[tuple[str, str]]
) -> tuple[int | None, list[str]]:
    if not isinstance(observations, list):
        return None, ["observations=missing"]
    failures: list[str] = []
    observed: set[tuple[str, str]] = set()
    duplicates: list[tuple[str, str]] = []
    for observation in observations:
        if not isinstance(observation, dict):
            failures.append(f"malformedObservation={observation!r}")
            continue
        mode = observation.get("mode")
        event = observation.get("event")
        if not isinstance(mode, str) or not isinstance(event, str):
            failures.append(f"observationIdentity={(mode, event)!r}")
            continue
        key = (mode, event)
        if key in observed:
            duplicates.append(key)
        observed.add(key)
        if observation.get("ok") is not True:
            failures.append(f"{mode}.{event}.ok={observation.get('ok')!r}")
        detail = observation.get("detail")
        if not isinstance(detail, str) or not detail:
            failures.append(f"{mode}.{event}.detail=missing")
    if duplicates:
        failures.append(f"duplicateObservations={sorted(duplicates)!r}")
    for required in required_observations:
        if required not in observed:
            failures.append(f"missingObservation={required!r}")
    return len(observations), failures


def check_model_artifact(path: str) -> dict[str, Any]:
    payload = read_json(path)
    if payload is None:
        return missing_required(
            "talk-turn-actor-model",
            "Talk Turn actor protocol model check",
            f"Run `just protocol-talk-turn-actor-model-check /tmp/tla2tools.jar {Path(path).parent}`.",
            path,
        )
    required_invariants = {
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
    }
    failures: list[str] = []
    if payload.get("ok") is not True or payload.get("status") != "pass":
        failures.append(f"status={payload.get('status')!r} ok={payload.get('ok')!r}")
    if str(payload.get("spec") or "") != "backend/specs/tla/TurboTalkTurnActor.tla":
        failures.append(f"spec={payload.get('spec')!r}")
    if str(payload.get("config") or "") != "backend/specs/tla/TurboTalkTurnActor.cfg":
        failures.append(f"config={payload.get('config')!r}")
    validation = find_step(payload, "tla-config-validation")
    if not isinstance(validation, dict):
        failures.append("tla-config-validation=missing")
        configured = set()
    else:
        if validation.get("ok") is not True:
            failures.append("tla-config-validation=failed")
        if validation.get("hasSpecification") is not True:
            failures.append("hasSpecification=false")
        configured_invariants = validation.get("configuredInvariants")
        configured = {
            str(item)
            for item in configured_invariants
            if isinstance(item, str)
        } if isinstance(configured_invariants, list) else set()
        missing = sorted(required_invariants - configured)
        if missing:
            failures.append(f"missingRequiredInvariants={missing!r}")
        if validation.get("missingDefinitions") not in ([], None):
            failures.append(f"missingDefinitions={validation.get('missingDefinitions')!r}")
        if validation.get("missingRequiredInvariants") not in ([], None):
            failures.append(f"validationMissingRequired={validation.get('missingRequiredInvariants')!r}")
    tlc = find_step(payload, "tlc")
    if not isinstance(tlc, dict):
        failures.append("tlc=missing")
        summary = []
    else:
        summary = tlc.get("summary") if isinstance(tlc.get("summary"), list) else []
        if tlc.get("ok") is not True or tlc.get("exitCode") != 0:
            failures.append(f"tlc=failed exitCode={tlc.get('exitCode')!r}")
        joined_summary = "\n".join(str(item) for item in summary)
        if "No error has been found" not in joined_summary:
            failures.append("tlcNoErrorSummary=missing")
        if not tlc_summary_has_explored_states(summary):
            failures.append(f"tlcStateExploration=missing summary={summary!r}")
        if not tlc.get("outputPath"):
            failures.append("tlcOutputPath=missing")
    detail = (
        f"model status={payload.get('status')!r} "
        f"configuredInvariants={len(configured)} "
        f"tlcSummaryLines={len(summary)}"
    )
    if failures:
        detail += f"; failures={failures!r}"
    return evidence(
        "talk-turn-actor-model",
        "Talk Turn actor protocol model check",
        "fail" if failures else "pass",
        path,
        detail,
    )


def tlc_summary_has_explored_states(summary: list[Any]) -> bool:
    for item in summary:
        text = str(item)
        if "states generated" not in text or "distinct states found" not in text:
            continue
        numbers = [int(value) for value in re.findall(r"\d+", text)]
        if len(numbers) >= 2 and numbers[0] > 0 and numbers[1] > 0:
            return True
    return False


def check_rust_postgres_integration(path: str) -> dict[str, Any]:
    payload = read_json(path)
    if payload is None:
        return missing_required(
            "rust-postgres-integration",
            "Rust runtime integration test against live Postgres/Redis",
            "Run `just rust-runtime-integration` after `just self-hosted-preflight` passes, then write the integration proof artifact.",
            path,
        )
    required_names = {
        "postgres-schema-application",
        "postgres-snapshot-loader",
        "talk-turn-db-constraints",
        "kernel-replay-idempotency",
        "post-commit-outbox-delivery",
        "websocket-authorization-facts",
        "redis-owner-record-cas",
    }
    required_proofs = payload.get("requiredProofs")
    observed_names = set()
    failed_proofs = []
    if isinstance(required_proofs, list):
        for proof in required_proofs:
            if not isinstance(proof, dict):
                continue
            name = proof.get("name")
            if isinstance(name, str):
                observed_names.add(name)
            if proof.get("status") != "pass":
                failed_proofs.append(
                    {
                        "name": name,
                        "status": proof.get("status"),
                        "reason": proof.get("reason"),
                    }
                )
    missing_proofs = sorted(required_names - observed_names)
    failures: list[str] = []
    if payload.get("ok") is not True or payload.get("status") != "pass":
        failures.append(f"status={payload.get('status')!r} ok={payload.get('ok')!r}")
    if missing_proofs:
        failures.append(f"missingProofs={missing_proofs!r}")
    if failed_proofs:
        failures.append(f"failedProofs={failed_proofs[:4]!r}")
    preflight = find_step(payload, "self-hosted-preflight")
    if not isinstance(preflight, dict):
        failures.append("self-hosted-preflight=missing")
    elif preflight.get("ok") is not True:
        failures.append(f"self-hosted-preflight=failed exitCode={preflight.get('exitCode')!r}")
    compose_up = find_step(payload, "compose-up")
    if not isinstance(compose_up, dict):
        failures.append("compose-up=missing")
    elif compose_up.get("ok") is not True:
        failures.append(f"compose-up=failed exitCode={compose_up.get('exitCode')!r}")
    service_readiness = find_step(payload, "service-readiness")
    if not isinstance(service_readiness, dict):
        failures.append("service-readiness=missing")
    elif service_readiness.get("ok") is not True:
        failures.append("service-readiness=failed")
    service_checks = service_readiness.get("checks") if isinstance(service_readiness, dict) else []
    service_check_by_name = {
        str(check.get("name") or ""): check
        for check in service_checks
        if isinstance(check, dict)
    } if isinstance(service_checks, list) else {}
    for service_name in ["postgres-tcp", "redis-tcp"]:
        check = service_check_by_name.get(service_name)
        if not isinstance(check, dict):
            failures.append(f"{service_name}=missing")
        elif check.get("ok") is not True:
            failures.append(f"{service_name}=failed")
    integration = find_step(payload, "request-talk-turn-postgres-redis-integration-test")
    if not isinstance(integration, dict):
        failures.append("request-talk-turn-postgres-redis-integration-test=missing")
    else:
        if integration.get("ok") is not True or integration.get("exitCode") != 0:
            failures.append(
                f"request-talk-turn-postgres-redis-integration-test=failed exitCode={integration.get('exitCode')!r}"
            )
        command = integration.get("command") if isinstance(integration.get("command"), list) else []
        if not command_has(
            command,
            [
                "cargo",
                "test",
                "-p",
                "beepbeep-runtime",
                "--test",
                "request_talk_turn_integration",
                "--ignored",
            ],
        ):
            failures.append("integration-test-command=invalid")
    detail = status_artifact_detail(payload)
    if failures:
        detail += f" failures={failures!r}"
    return evidence(
        "rust-postgres-integration",
        "Rust runtime integration test against live Postgres/Redis",
        "fail" if failures else "pass",
        path,
        detail,
    )


def command_has(command: list[Any], required_parts: list[str]) -> bool:
    values = [str(item) for item in command]
    return all(part in values for part in required_parts)


def check_physical_device_boundaries(path: str) -> dict[str, Any]:
    payload = read_json(path)
    if payload is None:
        return missing_required(
            "physical-device-boundaries",
            "Physical-device PTT/audio/QUIC/APNs cells",
            "Run `just physical-device-boundary-proof` after collecting physical-device PTT/audio/QUIC/APNs evidence.",
            path,
        )
    cells = payload.get("cells")
    failed_cells = []
    if isinstance(cells, list):
        failed_cells = [
            {
                "name": cell.get("name"),
                "reason": cell.get("reason"),
            }
            for cell in cells
            if isinstance(cell, dict) and cell.get("status") != "pass"
        ]
    ok = payload.get("ok") is True and payload.get("status") == "pass" and not failed_cells
    detail = status_artifact_detail(payload)
    if failed_cells:
        detail += f" failedCells={failed_cells[:4]!r}"
    result = evidence(
        "physical-device-boundaries",
        "Physical-device PTT/audio/QUIC/APNs cells",
        "pass" if ok else "fail",
        path,
        detail,
    )
    evidence_window = physical_device_evidence_window(payload)
    if evidence_window:
        result["physicalEvidenceWindow"] = evidence_window
    if not ok:
        result["remediation"] = physical_device_boundary_remediation(failed_cells)
        result["nextCommands"] = physical_device_boundary_next_commands(failed_cells)
        result["operatorStatusArtifact"] = DEFAULT_ARTIFACTS["physicalDeviceBoundaryStatus"]
        launchability = physical_device_launchability_summary(
            DEFAULT_ARTIFACTS["physicalDeviceBoundaryStatus"]
        )
        if launchability is not None:
            result["launchabilitySummary"] = launchability
        priority_actions = physical_device_priority_actions_summary(
            DEFAULT_ARTIFACTS["physicalDeviceBoundaryStatus"]
        )
        if priority_actions:
            result["physicalPriorityActions"] = priority_actions
        finalize_summary = physical_device_finalize_summary(
            DEFAULT_ARTIFACTS["physicalDeviceBoundaryFinalize"]
        )
        if finalize_summary:
            result["physicalFinalizeSummary"] = finalize_summary
    return result


def physical_device_finalize_summary(finalize_path: str) -> dict[str, Any]:
    payload = read_json(finalize_path)
    if not isinstance(payload, dict):
        return {}
    summary: dict[str, Any] = {
        "artifact": finalize_path,
        "status": str(payload.get("status") or "unknown"),
        "ok": payload.get("ok") is True,
    }
    skipped = payload.get("skippedMissingInputs")
    if isinstance(skipped, list):
        summary["skippedMissingInputs"] = [str(item) for item in skipped if str(item)]
    resolved = payload.get("resolvedManifests")
    if isinstance(resolved, list):
        summary["resolvedManifests"] = [str(item) for item in resolved if str(item)]
    proof_summary = payload.get("proofSummary")
    if isinstance(proof_summary, dict):
        summary["passedCells"] = proof_summary.get("passedCells") if isinstance(proof_summary.get("passedCells"), list) else []
        summary["failedCells"] = proof_summary.get("failedCells") if isinstance(proof_summary.get("failedCells"), list) else []
    return summary


def physical_device_evidence_window(payload: dict[str, Any]) -> dict[str, Any]:
    manifest_evidence_since = payload.get("manifestEvidenceSince")
    source_windows = payload.get("sourceEvidenceWindows")
    result: dict[str, Any] = {}
    if isinstance(manifest_evidence_since, str) and manifest_evidence_since:
        result["manifestEvidenceSince"] = manifest_evidence_since
    if isinstance(source_windows, list):
        compact_windows = [
            {
                "sourceManifest": str(window.get("sourceManifest") or ""),
                "evidenceSince": str(window.get("evidenceSince") or ""),
            }
            for window in source_windows
            if isinstance(window, dict)
        ]
        if compact_windows:
            result["sourceEvidenceWindows"] = compact_windows
    return result


def physical_device_launchability_summary(status_path: str) -> dict[str, Any] | None:
    status = read_json(status_path)
    if not isinstance(status, dict):
        return None
    probe = status.get("currentLaunchabilityProbe")
    if not isinstance(probe, dict):
        return None
    devices = probe.get("devices") if isinstance(probe.get("devices"), list) else []
    return {
        "artifact": probe.get("artifact") or "/tmp/turbo-device-launch-connected-current.json",
        "status": probe.get("status") or "unknown",
        "ok": probe.get("ok") is True,
        "launchablePhysicalDeviceCount": int(probe.get("launchablePhysicalDeviceCount") or 0),
        "failedPhysicalDeviceCount": int(probe.get("failedPhysicalDeviceCount") or 0),
        "failureReasons": probe.get("failureReasons") if isinstance(probe.get("failureReasons"), list) else [],
        "devices": [
            {
                "name": str(device.get("name") or ""),
                "udid": str(device.get("udid") or ""),
                "ok": device.get("ok") is True,
                "reason": str(device.get("reason") or ""),
            }
            for device in devices
            if isinstance(device, dict)
        ],
    }


def physical_device_priority_actions_summary(status_path: str) -> list[dict[str, Any]]:
    status = read_json(status_path)
    if not isinstance(status, dict):
        return []
    actions = status.get("priorityActions")
    if not isinstance(actions, list):
        return []
    return [
        compact_physical_priority_action(action)
        for action in actions[:6]
        if isinstance(action, dict)
    ]


def compact_physical_priority_action(action: dict[str, Any]) -> dict[str, Any]:
    keep_keys = [
        "kind",
        "cell",
        "device",
        "reason",
        "summary",
        "remediation",
        "verificationCommand",
        "verificationArtifact",
        "currentLaunchabilityProbe",
        "currentLockStateProbe",
        "command",
        "requirements",
        "missingEvidence",
        "missingContext",
        "wakeSendDiagnosis",
        "finalizeFailure",
    ]
    result = {key: action[key] for key in keep_keys if key in action}
    send_result = action.get("sendWakeApnsResult")
    if isinstance(send_result, dict) and send_result:
        result["sendWakeApnsResult"] = {
            key: send_result[key]
            for key in [
                "ok",
                "status",
                "stage",
                "channelId",
                "handle",
                "error",
                "body",
            ]
            if key in send_result
        }
    return result


def physical_device_boundary_remediation(failed_cells: list[dict[str, Any]]) -> str:
    failed_names = {
        cell.get("name")
        for cell in failed_cells
        if isinstance(cell.get("name"), str)
    }
    messages: list[str] = []
    if "direct-quic-media" in failed_names:
        messages.append(
            "Unlock both physical devices, keep them foregrounded, rerun the Direct QUIC target cell, and perform a PTT transmit while Direct QUIC is active."
        )
    if "lockscreen-apns-wake" in failed_names:
        messages.append(
            "Put the receiver in background or locked state, send a real PushToTalk APNs wake, verify playback, and rerun the lock-screen APNs target cell."
        )
    if "fallback-relay-audio" in failed_names:
        messages.append(
            "Rerun the fallback relay target cell with media relay forced and capture receiver playback."
        )
    if "foreground-ptt-audio" in failed_names:
        messages.append(
            "Rerun the foreground PTT audio target cell with both devices unlocked and foregrounded."
        )
    if not messages:
        messages.append("Rerun `just physical-device-boundary-proof` after collecting the missing physical evidence.")
    messages.append(
        "Run `just physical-device-boundary-status` for the current per-device operator blockers, then run the standard physical finalize command to merge collected cells into the canonical proof artifact."
    )
    return " ".join(messages)


def physical_device_boundary_next_commands(failed_cells: list[dict[str, Any]]) -> list[dict[str, str]]:
    failed_names = {
        cell.get("name")
        for cell in failed_cells
        if isinstance(cell.get("name"), str)
    }
    commands: list[dict[str, str]] = []
    if "direct-quic-media" in failed_names:
        commands.append(
            {
                "name": "verify-device-launchability",
                "command": "just device-launch-connected-json",
            }
        )
        commands.append(
            {
                "name": "collect-direct-quic-media",
                "command": (
                    'just physical-device-boundary-collect "" "" "" "" '
                    '/tmp/turbo-physical-direct-quic-run-current "" direct-quic "" 90 '
                    '"--target-cell direct-quic-media"'
                ),
            }
        )
    if "lockscreen-apns-wake" in failed_names:
        commands.append(
            {
                "name": "collect-lockscreen-apns-wake",
                "command": (
                    'just physical-device-boundary-collect "" "" "" "" '
                    '/tmp/turbo-physical-lockscreen-wake-run "" current '
                    '"--send-wake-apns --wake-channel-id <channel-id> --wake-handle <sender-handle>" '
                    '0 "--target-cell lockscreen-apns-wake"'
                ),
            }
        )
    if "fallback-relay-audio" in failed_names:
        commands.append(
            {
                "name": "collect-fallback-relay-audio",
                "command": (
                    'just physical-device-boundary-collect "" "" "" "" '
                    '/tmp/turbo-physical-fallback-relay-run "" fallback-relay "" 90 '
                    '"--target-cell fallback-relay-audio"'
                ),
            }
        )
    if "foreground-ptt-audio" in failed_names:
        commands.append(
            {
                "name": "collect-foreground-ptt-audio",
                "command": (
                    'just physical-device-boundary-collect "" "" "" "" '
                    '/tmp/turbo-physical-foreground-ptt-run "" current "" 90 '
                    '"--target-cell foreground-ptt-audio"'
                ),
            }
        )
    commands.append(
        {
            "name": "inspect-physical-device-boundary-status",
            "command": (
                'just physical-device-boundary-status '
                '/tmp/turbo-self-hosted-cutover-readiness-current.json '
                '"--run /tmp/turbo-physical-direct-quic-run-current '
                '--run /tmp/turbo-physical-lockscreen-wake-run '
                '--run /tmp/turbo-physical-fallback-relay-run '
                '--run /tmp/turbo-physical-foreground-ptt-run" '
                '/tmp/turbo-physical-device-boundary-status-current.json'
            ),
        }
    )
    commands.append(
        {
            "name": "finalize-canonical-physical-proof",
            "command": standard_physical_finalize_command(),
        }
    )
    return commands


def standard_physical_finalize_command() -> str:
    return (
        'just physical-device-boundary-finalize '
        '"/tmp/turbo-physical-direct-quic-run-current '
        '/tmp/turbo-physical-lockscreen-wake-run '
        '/tmp/turbo-physical-fallback-relay-run '
        '/tmp/turbo-physical-foreground-ptt-run"'
    )


def check_simulator_self_hosted_suite(path: str) -> dict[str, Any]:
    payload = read_json(path)
    if payload is None:
        return missing_required(
            "simulator-self-hosted-suite",
            "Simulator scenario suite against self-hosted base URL",
            "Run `just simulator-scenario-suite-self-hosted` once the live self-hosted runtime is available.",
            path,
        )
    failures: list[str] = []
    if payload.get("ok") is not True or payload.get("status") != "pass":
        failures.append(f"status={payload.get('status')!r} ok={payload.get('ok')!r}")
    base_url = payload.get("baseUrl")
    device_id_a = payload.get("deviceIDA")
    device_id_b = payload.get("deviceIDB")
    if not isinstance(base_url, str) or not base_url:
        failures.append("baseUrl=missing")
    for name, value in [("deviceIDA", device_id_a), ("deviceIDB", device_id_b)]:
        if not isinstance(value, str) or not value.startswith("sim-self-hosted-"):
            failures.append(f"{name}={value!r}")
    preflight = find_step(payload, "self-hosted-health-preflight")
    if not isinstance(preflight, dict):
        failures.append("self-hosted-health-preflight=missing")
    elif preflight.get("ok") is not True:
        failures.append("self-hosted-health-preflight=failed")
    preflight_checks = preflight.get("checks") if isinstance(preflight, dict) else []
    check_by_name = {
        str(check.get("name") or ""): check
        for check in preflight_checks
        if isinstance(preflight_checks, list) and isinstance(check, dict)
    } if isinstance(preflight_checks, list) else {}
    health = check_by_name.get("health")
    config = check_by_name.get("config")
    if not isinstance(health, dict):
        failures.append("health-preflight=missing")
    else:
        health_body = health.get("body") if isinstance(health.get("body"), dict) else {}
        if (
            health.get("ok") is not True
            or health_body.get("runtime") != "self-hosted"
            or health_body.get("supportsWebSocket") is not True
        ):
            failures.append(
                f"health-preflight=invalid runtime={health_body.get('runtime')!r} "
                f"supportsWebSocket={health_body.get('supportsWebSocket')!r}"
            )
    if not isinstance(config, dict):
        failures.append("config-preflight=missing")
    else:
        config_body = config.get("body") if isinstance(config.get("body"), dict) else {}
        if (
            config.get("ok") is not True
            or config_body.get("mode") != "self-hosted"
            or config_body.get("supportsWebSocket") is not True
        ):
            failures.append(
                f"config-preflight=invalid mode={config_body.get('mode')!r} "
                f"supportsWebSocket={config_body.get('supportsWebSocket')!r}"
            )
    scenario = find_step(payload, "simulator-scenario-suite-self-hosted")
    if not isinstance(scenario, dict):
        failures.append("simulator-scenario-suite-self-hosted=missing")
    else:
        if scenario.get("ok") is not True:
            failures.append(f"simulator-scenario-suite-self-hosted=failed exitCode={scenario.get('exitCode')!r}")
        command = scenario.get("command") if isinstance(scenario.get("command"), list) else []
        if not simulator_command_has(command, ["tools/scripts/run_simulator_scenarios.py", "--base-url", str(base_url)]):
            failures.append("simulator-scenario-command=invalid")
        failures.extend(simulator_scenario_stdout_failures(scenario.get("stdout")))
    diagnostics = find_step(payload, "simulator-self-hosted-merged-diagnostics-strict")
    if not isinstance(diagnostics, dict):
        failures.append("simulator-self-hosted-merged-diagnostics-strict=missing")
    else:
        if diagnostics.get("ok") is not True:
            failures.append(f"simulator-self-hosted-merged-diagnostics-strict=failed exitCode={diagnostics.get('exitCode')!r}")
        command = diagnostics.get("command") if isinstance(diagnostics.get("command"), list) else []
        required_command_parts = [
            "tools/scripts/merged_diagnostics.py",
            "--base-url",
            str(base_url),
            "--no-telemetry",
            "--fail-on-violations",
            f"{payload.get('handleA')}={device_id_a}",
            f"{payload.get('handleB')}={device_id_b}",
        ]
        if not simulator_command_has(command, required_command_parts):
            failures.append("strict-diagnostics-command=invalid")
    detail = status_artifact_detail(payload)
    if isinstance(scenario, dict) and not failures:
        detail += f" simulatorScenarioCount={checked_in_simulator_scenario_count()}"
    if preflight:
        failed_checks = [
            {
                "name": check.get("name"),
                "url": check.get("url"),
                "error": check.get("error"),
            }
            for check in preflight.get("checks", [])
            if isinstance(check, dict) and check.get("ok") is not True
        ]
        if failed_checks:
            detail += f" preflightFailures={failed_checks[:4]!r}"
    if failures:
        detail += f" failures={failures!r}"
    return evidence(
        "simulator-self-hosted-suite",
        "Simulator scenario suite against self-hosted base URL",
        "fail" if failures else "pass",
        path,
        detail,
    )


def simulator_scenario_stdout_failures(stdout: Any) -> list[str]:
    if not isinstance(stdout, str) or not stdout:
        return ["simulator-scenario-stdout=missing"]
    expected_count = checked_in_simulator_scenario_count()
    if expected_count <= 0:
        return ["checkedInScenarioCount=missing"]
    failures: list[str] = []
    run_markers = re.findall(r"Running simulator scenario (\d+)/(\d+):", stdout)
    finish_count = len(re.findall(r"Simulator scenario finished:", stdout))
    success_count = len(re.findall(r"\*\* TEST SUCCEEDED \*\*", stdout))
    expected_indices = {str(index) for index in range(1, expected_count + 1)}
    observed_indices = {index for index, total in run_markers if total == str(expected_count)}
    observed_totals = {total for _, total in run_markers}
    if len(run_markers) != expected_count:
        failures.append(f"scenarioRunMarkers={len(run_markers)} expected={expected_count}")
    if observed_totals != {str(expected_count)}:
        failures.append(f"scenarioRunTotals={sorted(observed_totals)!r}")
    missing_indices = sorted(expected_indices - observed_indices, key=int)
    if missing_indices:
        failures.append(f"scenarioRunMissingIndices={missing_indices[:8]!r}")
    if finish_count != expected_count:
        failures.append(f"scenarioFinishMarkers={finish_count} expected={expected_count}")
    if success_count != expected_count:
        failures.append(f"scenarioSuccessMarkers={success_count} expected={expected_count}")
    return failures


def checked_in_simulator_scenario_count() -> int:
    return len(list(Path("shared/scenarios").glob("*.json")))


def simulator_command_has(command: list[Any], required_parts: list[str]) -> bool:
    values = [str(item) for item in command]
    return all(part in values for part in required_parts)


def find_step(payload: dict[str, Any], name: str) -> dict[str, Any] | None:
    steps = payload.get("steps")
    if not isinstance(steps, list):
        return None
    for step in steps:
        if isinstance(step, dict) and step.get("name") == name:
            return step
    return None


def missing_required(
    name: str,
    description: str,
    remediation: str,
    path: str | None = None,
    *,
    required_for_cutover: bool = True,
) -> dict[str, Any]:
    result = evidence(
        name,
        description,
        "missing",
        path,
        remediation,
        required_for_cutover=required_for_cutover,
    )
    result["remediation"] = remediation
    return result


def evidence(
    name: str,
    description: str,
    status: str,
    path: str | None,
    detail: str,
    *,
    required_for_cutover: bool = True,
) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "status": status,
        "artifact": path,
        "detail": detail,
        "requiredForCutover": required_for_cutover,
    }


def status_artifact_detail(payload: dict[str, Any]) -> str:
    detail = f"artifact status={payload.get('status')!r} ok={payload.get('ok')!r}"
    steps = payload.get("steps")
    if isinstance(steps, list):
        failed_steps = [
            step.get("name")
            for step in steps
            if isinstance(step, dict) and step.get("ok") is not True and step.get("name")
        ]
        if failed_steps:
            detail += f" failedSteps={failed_steps[:4]!r}"
    return detail


def read_json(path: str) -> dict[str, Any] | None:
    artifact = Path(path)
    if not artifact.exists():
        return None
    try:
        payload = json.loads(artifact.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main())
