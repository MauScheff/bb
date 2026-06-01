#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import random
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_BASE_URL = "http://localhost:8090/s/turbo"
DEFAULT_ROOT = Path("/tmp/turbo-scenario-fuzz")
DEFAULT_HANDLE_A = "@avery"
DEFAULT_HANDLE_B = "@blake"
MIN_FREE_BYTES_FOR_FUZZ_RUN = 4 * 1024 * 1024 * 1024
HTTP_ROUTES = [
    "contact-summaries",
    "incoming-beeps",
    "outgoing-beeps",
    "channel-state",
    "channel-readiness",
    "renew-transmit",
]
SIGNAL_KINDS = [
    "transmit-start",
    "transmit-stop",
    "receiver-ready",
    "receiver-not-ready",
]
CORE_SCENARIO_ACTION_TYPES = {
    "openFriend",
    "connect",
    "beginTransmit",
    "endTransmit",
    "backgroundApp",
    "foregroundApp",
    "disconnect",
    "restartApp",
}
POST_TRANSMIT_PERTURBATIONS = [
    "normal_stop",
    "sender_disconnect",
    "wake_token_revocation",
]
INVALID_SCENARIO_FAILURE_MARKERS = [
    "Caught error: Scenario references unknown actor",
    "Caught error: openFriend requires",
    "Caught error: ensureDirectChannel requires",
    "Caught error: heartbeatPresence requires",
    "Caught error: refreshChannelState requires",
    "Caught error: refreshChannelStateAsync requires",
    "Caught error: setHTTPDelay requires",
    "Caught error: setWebSocketSignalDelay requires",
    "Caught error: dropNextWebSocketSignals requires",
    "Caught error: duplicateNextWebSocketSignals requires",
    "Caught error: reorderNextWebSocketSignals requires",
    "Caught error: reconnectWebSocket requires",
    "Caught error: restartApp requires",
    "Caught error: wait requires",
    "Caught error: Unknown scenario action type",
    "Caught error: Scenario action ",
]


@dataclass(frozen=True)
class FuzzRunConfig:
    seed: int
    count: int
    base_url: str
    artifact_root: Path
    stop_on_first_failure: bool
    handle_a: str
    handle_b: str


@dataclass(frozen=True)
class ScenarioRunResult:
    failed: bool
    scenario_exit_code: int
    strict_diagnostics_exit_code: int
    engine_trace_extract_exit_code: int
    engine_trace_replay_exit_code: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate deterministic Turbo simulator scenarios and run them through the existing XCTest harness."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="Generate and run a batch of fuzz scenarios.")
    run_parser.add_argument("--seed", type=int, required=True)
    run_parser.add_argument("--count", type=int, required=True)
    run_parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    run_parser.add_argument("--artifact-root", default=str(DEFAULT_ROOT))
    run_parser.add_argument("--stop-on-first-failure", action="store_true")
    run_parser.add_argument("--handle-a", default=DEFAULT_HANDLE_A)
    run_parser.add_argument("--handle-b", default=DEFAULT_HANDLE_B)

    replay_parser = subparsers.add_parser("replay", help="Replay a saved fuzz artifact directory.")
    replay_parser.add_argument("--artifact-dir", required=True)

    shrink_parser = subparsers.add_parser("shrink", help="Shrink a saved failing fuzz artifact directory.")
    shrink_parser.add_argument("--artifact-dir", required=True)
    shrink_parser.add_argument("--max-candidates", type=int, default=80)

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "run":
        config = FuzzRunConfig(
            seed=args.seed,
            count=args.count,
            base_url=args.base_url,
            artifact_root=Path(args.artifact_root),
            stop_on_first_failure=args.stop_on_first_failure,
            handle_a=args.handle_a,
            handle_b=args.handle_b,
        )
        return run_batch(config)
    if args.command == "replay":
        return replay(Path(args.artifact_dir))
    if args.command == "shrink":
        return shrink(Path(args.artifact_dir), max_candidates=args.max_candidates)
    raise AssertionError(f"unknown command {args.command}")


def run_batch(config: FuzzRunConfig) -> int:
    ensure_free_space(config.artifact_root, MIN_FREE_BYTES_FOR_FUZZ_RUN)
    run_id = f"{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
    run_dir = config.artifact_root / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    write_json(
        run_dir / "run-metadata.json",
        {
            "seed": config.seed,
            "count": config.count,
            "baseURL": config.base_url,
            "stopOnFirstFailure": config.stop_on_first_failure,
            "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
    )
    print(f"fuzz artifacts: {run_dir}", flush=True)

    first_failure: Path | None = None
    for index in range(config.count):
        seed = config.seed + index
        scenario_dir = run_dir / f"seed-{seed}"
        scenario_dir.mkdir(parents=True, exist_ok=True)
        scenario = generate_scenario(
            seed=seed,
            base_url=config.base_url,
            handle_a=config.handle_a,
            handle_b=config.handle_b,
            device_id_a=f"sim-fuzz-{seed}-avery",
            device_id_b=f"sim-fuzz-{seed}-blake",
        )
        write_scenario_artifacts(scenario_dir, scenario, seed, config.base_url)
        print(f"[{index + 1}/{config.count}] seed={seed}", flush=True)
        result = run_artifact_scenario(scenario_dir)
        write_json(
            scenario_dir / "result.json",
            {
                "failed": result.failed,
                "scenarioExitCode": result.scenario_exit_code,
                "strictDiagnosticsExitCode": result.strict_diagnostics_exit_code,
                "engineTraceExtractExitCode": result.engine_trace_extract_exit_code,
                "engineTraceReplayExitCode": result.engine_trace_replay_exit_code,
            },
        )
        if result.failed:
            first_failure = scenario_dir
            print(f"failure seed={seed}", flush=True)
            print(f"replay: just simulator-fuzz-replay {scenario_dir}", flush=True)
            print(f"shrink: just simulator-fuzz-shrink {scenario_dir}", flush=True)
            if config.stop_on_first_failure:
                break

    if first_failure is not None:
        return 1
    print(f"all fuzz seeds passed; artifacts: {run_dir}", flush=True)
    return 0


def replay(artifact_dir: Path) -> int:
    require_artifact(artifact_dir)
    result = run_artifact_scenario(artifact_dir)
    write_json(
        artifact_dir / "result.json",
        {
            "failed": result.failed,
            "scenarioExitCode": result.scenario_exit_code,
            "strictDiagnosticsExitCode": result.strict_diagnostics_exit_code,
            "engineTraceExtractExitCode": result.engine_trace_extract_exit_code,
            "engineTraceReplayExitCode": result.engine_trace_replay_exit_code,
        },
    )
    return 1 if result.failed else 0


def shrink(artifact_dir: Path, max_candidates: int) -> int:
    require_artifact(artifact_dir)
    scenario_path = preferred_scenario_path(artifact_dir)
    scenario = read_json(scenario_path)
    candidates_run = 0
    changed = True
    current = scenario

    while changed and candidates_run < max_candidates:
        changed = False
        for candidate in shrink_candidates(current):
            candidates_run += 1
            candidate_dir = artifact_dir / "shrink-candidates" / f"candidate-{candidates_run:04d}"
            candidate_dir.mkdir(parents=True, exist_ok=True)
            write_scenario_artifacts(candidate_dir, candidate, metadata(artifact_dir)["seed"], metadata(artifact_dir)["baseURL"])
            result = run_artifact_scenario(candidate_dir)
            write_json(
                candidate_dir / "result.json",
                {
                    "failed": result.failed,
                    "scenarioExitCode": result.scenario_exit_code,
                    "strictDiagnosticsExitCode": result.strict_diagnostics_exit_code,
                    "engineTraceExtractExitCode": result.engine_trace_extract_exit_code,
                    "engineTraceReplayExitCode": result.engine_trace_replay_exit_code,
                    "invalidScenarioProgram": invalid_scenario_program_failure(candidate_dir, result),
                },
            )
            if result.failed:
                if invalid_scenario_program_failure(candidate_dir, result):
                    print(f"rejected invalid shrink candidate {candidates_run}", flush=True)
                    continue
                current = candidate
                write_json(artifact_dir / "minimized.json", current)
                shutil.copy2(candidate_dir / "xcode-output.txt", artifact_dir / "minimized-xcode-output.txt")
                changed = True
                print(f"accepted shrink candidate {candidates_run}", flush=True)
                break

    write_json(
        artifact_dir / "shrink-result.json",
        {
            "candidatesRun": candidates_run,
            "minimizedScenario": str((artifact_dir / "minimized.json").resolve())
                if (artifact_dir / "minimized.json").exists()
                else None,
        },
    )
    if (artifact_dir / "minimized.json").exists():
        print(f"minimized: {artifact_dir / 'minimized.json'}", flush=True)
        return 0
    print("no shrinking candidate preserved the failure", flush=True)
    return 1


def write_scenario_artifacts(artifact_dir: Path, scenario: dict[str, Any], seed: int, base_url: str) -> None:
    write_json(artifact_dir / "scenario.json", scenario)
    write_json(
        artifact_dir / "metadata.json",
        {
            "seed": seed,
            "scenarioName": scenario["name"],
            "baseURL": base_url,
            "handleA": scenario["participants"]["a"]["handle"],
            "handleB": scenario["participants"]["b"]["handle"],
            "deviceIDA": scenario["participants"]["a"]["deviceId"],
            "deviceIDB": scenario["participants"]["b"]["deviceId"],
            "replayCommand": f"just simulator-fuzz-replay {artifact_dir}",
        },
    )


def run_artifact_scenario(artifact_dir: Path) -> ScenarioRunResult:
    meta = metadata(artifact_dir)
    scenario_file = preferred_scenario_path(artifact_dir)
    repo_root = Path.cwd()
    scenario_command = [
        "python3",
        "tools/scripts/run_simulator_scenarios.py",
        "--scenario-file",
        str(scenario_file),
        "--scenario",
        meta["scenarioName"],
        "--base-url",
        meta["baseURL"],
        "--handle-a",
        meta["handleA"],
        "--handle-b",
        meta["handleB"],
        "--device-id-a",
        meta["deviceIDA"],
        "--device-id-b",
        meta["deviceIDB"],
    ]
    (artifact_dir / "reproduce.sh").write_text(
        f"#!/usr/bin/env bash\nset -euo pipefail\ncd {shell_quote(str(repo_root))}\n"
        + " ".join(shell_quote(part) for part in scenario_command)
        + "\n",
        encoding="utf-8",
    )
    scenario_result = run_and_capture(scenario_command, artifact_dir / "xcode-output.txt")

    diagnostics_text_command = diagnostics_command(meta, json_output=False, fail_on_violations=False)
    run_and_capture(diagnostics_text_command, artifact_dir / "merged-diagnostics.txt", echo=False)

    diagnostics_json_command = diagnostics_command(meta, json_output=True, fail_on_violations=False)
    run_and_capture(diagnostics_json_command, artifact_dir / "merged-diagnostics.json", echo=False)

    strict_command = diagnostics_command(meta, json_output=False, fail_on_violations=True)
    strict_result = run_and_capture(strict_command, artifact_dir / "merged-diagnostics-strict.txt", echo=False)

    trace_path = artifact_dir / "engine-trace.json"
    trace_extract_result = run_and_capture(
        [
            "python3",
            "tools/scripts/extract_engine_trace.py",
            str(artifact_dir / "merged-diagnostics.json"),
            "--output",
            str(trace_path),
        ],
        artifact_dir / "engine-trace-extract.txt",
        echo=False,
    )
    if trace_extract_result.returncode == 0:
        trace_replay_result = run_and_capture(
            [
                "swift",
                "run",
                "--package-path",
                "client/ios/Packages/TurboEngine",
                "turbo-engine",
                "trace-replay",
                str(trace_path),
            ],
            artifact_dir / "engine-trace-replay.txt",
            echo=False,
        )
    else:
        trace_replay_result = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="engine trace extraction failed; replay skipped\n",
            stderr=None,
        )
        (artifact_dir / "engine-trace-replay.txt").write_text(trace_replay_result.stdout, encoding="utf-8")

    return ScenarioRunResult(
        failed=(
            scenario_result.returncode != 0
            or strict_result.returncode != 0
            or trace_extract_result.returncode != 0
            or trace_replay_result.returncode != 0
        ),
        scenario_exit_code=scenario_result.returncode,
        strict_diagnostics_exit_code=strict_result.returncode,
        engine_trace_extract_exit_code=trace_extract_result.returncode,
        engine_trace_replay_exit_code=trace_replay_result.returncode,
    )


def invalid_scenario_program_failure(artifact_dir: Path, result: ScenarioRunResult) -> bool:
    if result.scenario_exit_code == 0:
        return False
    output_path = artifact_dir / "xcode-output.txt"
    if not output_path.exists():
        return False
    output = output_path.read_text(encoding="utf-8", errors="replace")
    return any(marker in output for marker in INVALID_SCENARIO_FAILURE_MARKERS)


def diagnostics_command(meta: dict[str, Any], *, json_output: bool, fail_on_violations: bool) -> list[str]:
    command = [
        "python3",
        "tools/scripts/merged_diagnostics.py",
        "--base-url",
        meta["baseURL"],
        "--no-telemetry",
        "--device",
        f"{meta['handleA']}={meta['deviceIDA']}",
        "--device",
        f"{meta['handleB']}={meta['deviceIDB']}",
    ]
    if json_output:
        command.append("--json")
    if fail_on_violations:
        command.append("--fail-on-violations")
    return command


def run_and_capture(command: list[str], output_path: Path, *, echo: bool = True) -> subprocess.CompletedProcess[str]:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    collected: list[str] = []
    assert process.stdout is not None
    for line in process.stdout:
        collected.append(line)
        if echo:
            sys.stdout.write(line)
            sys.stdout.flush()
    returncode = process.wait()
    output_path.write_text("".join(collected), encoding="utf-8")
    return subprocess.CompletedProcess(command, returncode, "".join(collected), "")


def generate_scenario(
    *,
    seed: int,
    base_url: str,
    handle_a: str,
    handle_b: str,
    device_id_a: str,
    device_id_b: str,
) -> dict[str, Any]:
    rng = random.Random(seed)
    name = f"fuzz_seed_{seed}"
    steps: list[dict[str, Any]] = [
        step(
            "both Friends open each other",
            [
                {"actor": "a", "type": "openFriend", "friend": "b"},
                {"actor": "b", "type": "openFriend", "friend": "a"},
            ],
        ),
    ]
    maybe_noise_step(rng, steps, "pre-Beep refresh noise")
    steps.append(
        step(
            "Beep reaches recipient",
            maybe_action_faults(rng)
            + [{"actor": "a", "type": "connect"}]
            + maybe_refreshes(rng),
            expect={
                "a": {"selectedHandle": handle_b, "phase": "outgoingBeep", "isJoined": False},
                "b": {"selectedHandle": handle_a, "phase": "incomingBeep", "isJoined": False},
            },
        )
    )
    steps.append(
        step(
            "recipient joins and sender becomes friendReady",
            maybe_action_faults(rng)
            + [{"actor": "b", "type": "connect"}]
            + maybe_refreshes(rng),
            expect={
                "a": {"selectedHandle": handle_b, "phase": "friendReady", "isJoined": False},
                "b": {"selectedHandle": handle_a, "phase": "waitingForPeer", "isJoined": True},
            },
        )
    )
    steps.append(
        step(
            "both sides become ready",
            maybe_action_faults(rng)
            + [{"actor": "a", "type": "connect"}]
            + maybe_refreshes(rng),
            expect={
                "a": {"selectedHandle": handle_b, "phase": "ready", "isJoined": True, "canTransmitNow": True},
                "b": {"selectedHandle": handle_a, "phase": "ready", "isJoined": True, "canTransmitNow": True},
            },
        )
    )

    if rng.random() < 0.35:
        actor = rng.choice(["a", "b"])
        steps.append(step("websocket reconnect perturbation", [{"actor": actor, "type": "disconnectWebSocket"}]))
        steps.append(
            step(
                "websocket reconnect recovers",
                [{"actor": actor, "type": "reconnectWebSocket"}] + both_refreshes(),
                expect={
                    "a": {"selectedHandle": handle_b, "isJoined": True},
                    "b": {"selectedHandle": handle_a, "isJoined": True},
                },
            )
        )

    if rng.random() < 0.25:
        actor = rng.choice(["a", "b"])
        steps.append(step("app restart perturbation", [{"actor": actor, "type": "restartApp"}]))
        steps.append(
            step(
                "restart refresh and rejoin recovers selected Conversation",
                [{"actor": actor, "type": "openFriend", "friend": friend_for(actor)}]
                + both_refreshes()
                + [
                    {"actor": actor, "type": "reconcileSelectedConversation"},
                    {"actor": actor, "type": "connect"},
                ]
                + both_refreshes(),
                expect={
                    "a": {"selectedHandle": handle_b, "isJoined": True},
                    "b": {"selectedHandle": handle_a, "isJoined": True},
                },
            )
        )

    transmitter = rng.choice(["a", "b"])
    receiver = friend_for(transmitter)
    post_transmit_perturbation = rng.choices(
        POST_TRANSMIT_PERTURBATIONS,
        weights=[55, 25, 20],
        k=1,
    )[0]

    if post_transmit_perturbation == "wake_token_revocation":
        steps.append(
            step(
                "receiver backgrounds before wake-token transmit",
                [{"actor": receiver, "type": "backgroundApp"}] + maybe_refreshes(rng, actor=transmitter),
                expect={
                    transmitter: {
                        "selectedHandle": handle_for(receiver, handle_a, handle_b),
                        "isJoined": True,
                        "eventuallyNoInvariant": ["channel.active_transmit_without_addressable_receiver"],
                    },
                    receiver: {
                        "selectedHandle": handle_for(transmitter, handle_a, handle_b),
                        "eventuallyNoInvariant": ["channel.active_transmit_without_addressable_receiver"],
                    },
                },
            )
        )

    transmit_expect: dict[str, Any] = {
        transmitter: {
            "selectedHandle": handle_for(receiver, handle_a, handle_b),
            "phase": "transmitting",
            "isJoined": True,
            "isTransmitting": True,
        }
    }
    if post_transmit_perturbation != "wake_token_revocation":
        transmit_expect[receiver] = {
            "selectedHandle": handle_for(transmitter, handle_a, handle_b),
            "phase": "receiving",
            "isJoined": True,
        }

    steps.append(
        step(
            f"{transmitter} begins transmitting",
            transmit_faults_for_receiver(rng, receiver)
            + [{"actor": transmitter, "type": "beginTransmit"}]
            + maybe_refreshes(rng, actor=receiver),
            expect=transmit_expect,
        )
    )

    if post_transmit_perturbation == "sender_disconnect":
        steps.append(
            step(
                "active transmitter disconnects while live",
                [{"actor": transmitter, "type": "disconnect"}]
                + both_refreshes()
                + [
                    {"actor": "a", "type": "reconcileSelectedConversation"},
                    {"actor": "b", "type": "reconcileSelectedConversation"},
                    {"actor": "a", "type": "captureDiagnostics", "delayMilliseconds": 500},
                    {"actor": "b", "type": "captureDiagnostics", "delayMilliseconds": 500},
                ],
                expect={
                    "a": {
                        "selectedHandle": handle_b,
                        "isJoined": False,
                        "isTransmitting": False,
                        "eventuallyNoInvariant": [
                            "channel.active_transmit_sender_presence_drift",
                            "channel.active_transmit_without_addressable_receiver",
                            "selected.live_projection_after_membership_exit",
                        ],
                    },
                    "b": {
                        "selectedHandle": handle_a,
                        "isJoined": False,
                        "isTransmitting": False,
                        "eventuallyNoInvariant": [
                            "channel.active_transmit_sender_presence_drift",
                            "channel.active_transmit_without_addressable_receiver",
                            "selected.live_projection_after_membership_exit",
                        ],
                    },
                },
            )
        )
        return scenario_payload(name, base_url, handle_a, handle_b, device_id_a, device_id_b, steps)

    if post_transmit_perturbation == "wake_token_revocation":
        steps.append(
            step(
                "receiver wake token revocation clears addressability",
                [{"actor": receiver, "type": "revokeEphemeralToken"}]
                + maybe_refreshes(rng, actor=transmitter)
                + [
                    {"actor": transmitter, "type": "refreshChannelState", "delayMilliseconds": 500},
                    {"actor": "a", "type": "captureDiagnostics", "delayMilliseconds": 800},
                    {"actor": "b", "type": "captureDiagnostics", "delayMilliseconds": 800},
                ],
                expect={
                    transmitter: {
                        "selectedHandle": handle_for(receiver, handle_a, handle_b),
                        "isJoined": True,
                        "isTransmitting": False,
                        "eventuallyNoInvariant": ["channel.active_transmit_without_addressable_receiver"],
                    },
                    receiver: {
                        "selectedHandle": handle_for(transmitter, handle_a, handle_b),
                        "isJoined": True,
                        "eventuallyNoInvariant": ["channel.active_transmit_without_addressable_receiver"],
                    },
                },
            )
        )
        return scenario_payload(name, base_url, handle_a, handle_b, device_id_a, device_id_b, steps)

    steps.append(
        step(
            f"{transmitter} ends transmitting",
            maybe_stale_backend_refresh_race(rng, receiver)
            + [{"actor": transmitter, "type": "endTransmit", "delayMilliseconds": 50}]
            + maybe_refreshes(rng),
            expect={
                "a": {"selectedHandle": handle_b, "phase": "ready", "isJoined": True, "isTransmitting": False},
                "b": {"selectedHandle": handle_a, "phase": "ready", "isJoined": True, "isTransmitting": False},
            },
        )
    )

    if rng.random() < 0.3:
        actor = rng.choice(["a", "b"])
        steps.append(step("background foreground perturbation", [{"actor": actor, "type": "backgroundApp"}]))
        steps.append(step("foreground refresh", [{"actor": actor, "type": "foregroundApp"}] + both_refreshes()))

    disconnect_actor = rng.choice(["a", "b"])
    steps.append(
        step(
            "disconnect clears joined state",
            maybe_stale_backend_refresh_race(rng, disconnect_actor)
            + [{"actor": disconnect_actor, "type": "disconnect", "delayMilliseconds": 50}]
            + maybe_refreshes(rng)
            + [
                {"actor": "a", "type": "reconcileSelectedConversation", "delayMilliseconds": 450},
                {"actor": "b", "type": "reconcileSelectedConversation", "delayMilliseconds": 450},
                {"actor": "a", "type": "captureDiagnostics", "delayMilliseconds": 800},
                {"actor": "b", "type": "captureDiagnostics", "delayMilliseconds": 800},
            ],
            expect={
                "a": {"selectedHandle": handle_b, "isJoined": False, "isTransmitting": False},
                "b": {"selectedHandle": handle_a, "isJoined": False, "isTransmitting": False},
            },
        )
    )

    return scenario_payload(name, base_url, handle_a, handle_b, device_id_a, device_id_b, steps)


def scenario_payload(
    name: str,
    base_url: str,
    handle_a: str,
    handle_b: str,
    device_id_a: str,
    device_id_b: str,
    steps: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "name": name,
        "baseURL": base_url,
        "requiresLocalBackend": True,
        "participants": {
            "a": {"handle": handle_a, "deviceId": device_id_a},
            "b": {"handle": handle_b, "deviceId": device_id_b},
        },
        "steps": steps,
    }


def step(description: str, actions: list[dict[str, Any]], expect: dict[str, Any] | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {"description": description, "actions": actions}
    if expect is not None:
        payload["expectEventually"] = expect
    return payload


def maybe_noise_step(rng: random.Random, steps: list[dict[str, Any]], description: str) -> None:
    actions = maybe_refreshes(rng)
    if actions:
        steps.append(step(description, actions))


def maybe_action_faults(rng: random.Random) -> list[dict[str, Any]]:
    actions: list[dict[str, Any]] = []
    if rng.random() < 0.35:
        actions.append(
            {
                "actor": rng.choice(["a", "b"]),
                "type": "setHTTPDelay",
                "route": rng.choice(HTTP_ROUTES),
                "milliseconds": rng.choice([0, 50, 150, 300, 600]),
                "count": rng.randint(1, 2),
            }
        )
    if rng.random() < 0.28:
        signal_kind = rng.choice(SIGNAL_KINDS)
        roll = rng.random()
        if roll < 0.35:
            actions.append(
                {
                    "actor": rng.choice(["a", "b"]),
                    "type": "setWebSocketSignalDelay",
                    "signalKind": signal_kind,
                    "milliseconds": rng.choice([100, 250, 500, 900]),
                    "count": rng.randint(1, 2),
                }
            )
        elif roll < 0.6:
            actions.append(
                {
                    "actor": rng.choice(["a", "b"]),
                    "type": "duplicateNextWebSocketSignals",
                    "signalKind": signal_kind,
                    "count": 1,
                }
            )
        elif roll < 0.82:
            actions.append(
                {
                    "actor": rng.choice(["a", "b"]),
                    "type": "dropNextWebSocketSignals",
                    "signalKind": signal_kind,
                    "count": 1,
                }
            )
        else:
            actions.append(
                {
                    "actor": rng.choice(["a", "b"]),
                    "type": "reorderNextWebSocketSignals",
                    "signalKind": signal_kind,
                    "count": 2,
                }
            )
    return actions


def maybe_refreshes(rng: random.Random, actor: str | None = None) -> list[dict[str, Any]]:
    actions: list[dict[str, Any]] = []
    actors = [actor] if actor else ["a", "b"]
    for selected_actor in actors:
        if rng.random() < 0.45:
            actions.append(with_delivery_noise(rng, {"actor": selected_actor, "type": "refreshContactSummaries"}))
        if rng.random() < 0.35:
            actions.append(with_delivery_noise(rng, {"actor": selected_actor, "type": "refreshBeeps"}))
        if rng.random() < 0.55:
            actions.append(with_delivery_noise(rng, {"actor": selected_actor, "type": "refreshChannelState"}))
        if rng.random() < 0.18:
            actions.append(with_delivery_noise(rng, {"actor": selected_actor, "type": "refreshChannelStateAsync"}))
    return actions


def maybe_stale_backend_refresh_race(rng: random.Random, actor: str) -> list[dict[str, Any]]:
    if rng.random() >= 0.5:
        return []
    route = rng.choice(["channel-state", "channel-readiness"])
    return [
        {
            "actor": actor,
            "type": "setHTTPDelay",
            "route": route,
            "milliseconds": rng.choice([300, 600, 900]),
            "count": 1,
        },
        {"actor": actor, "type": "refreshChannelStateAsync"},
    ]


def both_refreshes() -> list[dict[str, Any]]:
    return [
        {"actor": "a", "type": "refreshContactSummaries"},
        {"actor": "a", "type": "refreshBeeps"},
        {"actor": "a", "type": "refreshChannelState"},
        {"actor": "b", "type": "refreshContactSummaries"},
        {"actor": "b", "type": "refreshBeeps"},
        {"actor": "b", "type": "refreshChannelState"},
    ]


def with_delivery_noise(rng: random.Random, action: dict[str, Any]) -> dict[str, Any]:
    result = dict(action)
    if rng.random() < 0.35:
        result["delayMilliseconds"] = rng.choice([50, 150, 300, 600])
    if rng.random() < 0.18:
        result["repeatCount"] = rng.randint(2, 3)
        result["repeatIntervalMilliseconds"] = rng.choice([25, 75, 150])
    return result


def transmit_faults_for_receiver(rng: random.Random, receiver: str) -> list[dict[str, Any]]:
    actions: list[dict[str, Any]] = []
    roll = rng.random()
    if roll < 0.25:
        actions.append({"actor": receiver, "type": "dropNextWebSocketSignals", "signalKind": "transmit-start", "count": 1})
    elif roll < 0.45:
        actions.append({"actor": receiver, "type": "duplicateNextWebSocketSignals", "signalKind": "transmit-stop", "count": 1})
    elif roll < 0.65:
        actions.append({"actor": receiver, "type": "setWebSocketSignalDelay", "signalKind": "transmit-start", "milliseconds": 250, "count": 1})
    elif roll < 0.8:
        actions.append({"actor": receiver, "type": "reorderNextWebSocketSignals", "signalKind": "transmit-start", "count": 2})
    return actions


def shrink_candidates(scenario: dict[str, Any]) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    steps = scenario.get("steps", [])
    for index, step_payload in enumerate(steps):
        if len(steps) <= 1:
            break
        if not removable_step_for_shrink(step_payload):
            continue
        candidate = clone_json(scenario)
        del candidate["steps"][index]
        candidates.append(candidate)

    for step_index, step_payload in enumerate(steps):
        actions = step_payload.get("actions", [])
        for action_index, action in enumerate(actions):
            if len(actions) <= 1:
                continue
            if not removable_action_for_shrink(action):
                continue
            candidate = clone_json(scenario)
            del candidate["steps"][step_index]["actions"][action_index]
            candidates.append(candidate)

    for step_index, step_payload in enumerate(steps):
        for action_index, action in enumerate(step_payload.get("actions", [])):
            simplified = simplify_action(action)
            if simplified != action:
                candidate = clone_json(scenario)
                candidate["steps"][step_index]["actions"][action_index] = simplified
                candidates.append(candidate)

    return candidates


def removable_step_for_shrink(step_payload: dict[str, Any]) -> bool:
    if step_payload.get("expectEventually") is not None:
        return False
    return all(removable_action_for_shrink(action) for action in step_payload.get("actions", []))


def removable_action_for_shrink(action: dict[str, Any]) -> bool:
    return action.get("type") not in CORE_SCENARIO_ACTION_TYPES


def simplify_action(action: dict[str, Any]) -> dict[str, Any]:
    simplified = dict(action)
    if "delayMilliseconds" in simplified:
        simplified["delayMilliseconds"] = 0
    if "repeatCount" in simplified:
        simplified["repeatCount"] = 1
    if "repeatIntervalMilliseconds" in simplified:
        simplified["repeatIntervalMilliseconds"] = 0
    if "milliseconds" in simplified:
        simplified["milliseconds"] = 0
    if "count" in simplified:
        simplified["count"] = 2 if simplified.get("type") == "reorderNextWebSocketSignals" else 1
    return simplified


def friend_for(actor: str) -> str:
    return "b" if actor == "a" else "a"


def handle_for(actor: str, handle_a: str, handle_b: str) -> str:
    return handle_a if actor == "a" else handle_b


def preferred_scenario_path(artifact_dir: Path) -> Path:
    minimized = artifact_dir / "minimized.json"
    if minimized.exists():
        return minimized
    return artifact_dir / "scenario.json"


def metadata(artifact_dir: Path) -> dict[str, Any]:
    return read_json(artifact_dir / "metadata.json")


def require_artifact(artifact_dir: Path) -> None:
    if not (artifact_dir / "metadata.json").exists() or not (artifact_dir / "scenario.json").exists():
        raise SystemExit(f"not a fuzz artifact directory: {artifact_dir}")


def ensure_free_space(path: Path, required_bytes: int) -> None:
    path.mkdir(parents=True, exist_ok=True)
    free_bytes = shutil.disk_usage(path).free
    if free_bytes < required_bytes:
        required_gib = required_bytes / (1024 * 1024 * 1024)
        free_gib = free_bytes / (1024 * 1024 * 1024)
        raise SystemExit(
            "not enough free disk for simulator fuzz artifacts: "
            f"{free_gib:.1f} GiB available, {required_gib:.1f} GiB required at {path}"
        )


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def clone_json(payload: Any) -> Any:
    return json.loads(json.dumps(payload))


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    raise SystemExit(main())
