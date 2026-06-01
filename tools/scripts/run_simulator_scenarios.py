#!/usr/bin/env python3

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import urlparse


TRANSIENT_FAILURE_MARKERS = (
    "Early unexpected exit",
    "operation never finished bootstrapping",
    "Restarting after unexpected exit, crash, or test timeout",
    "lost connection to test process",
    "Failed to background test runner",
    "test crashed with signal",
    "Simulator device failed to launch",
    "Application failed preflight checks",
    "reason: Busy",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Turbo simulator scenarios with locking and transient retries.")
    parser.add_argument("--project", default="client/ios/Turbo.xcodeproj")
    parser.add_argument("--scheme", default="BeepBeep")
    parser.add_argument("--destination", default="platform=iOS Simulator,name=iPhone 17")
    parser.add_argument("--derived-data", default="/tmp/turbo-dd-simulator-scenario")
    parser.add_argument("--scenario", default="")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--handle-a", default="@avery")
    parser.add_argument("--handle-b", default="@blake")
    parser.add_argument("--device-id-a", default="sim-scenario-avery")
    parser.add_argument("--device-id-b", default="sim-scenario-blake")
    parser.add_argument("--lock-file", default=".scenario-test.lock")
    parser.add_argument("--simulator-lock-file", default="/tmp/turbo-simulator-test.lock")
    parser.add_argument("--runtime-config", default=".scenario-runtime-config.json")
    parser.add_argument("--scenario-file", default="")
    parser.add_argument("--scenario-directory", default="")
    parser.add_argument("--control-command-transport-policy", default="")
    parser.add_argument("--max-attempts", type=int, default=2)
    parser.add_argument("--catalog-scenario-attempts", type=int, default=2)
    parser.add_argument("--retry-delay-seconds", type=float, default=3.0)
    return parser.parse_args()


def write_runtime_config(path: Path, args: argparse.Namespace, scenario_filter: str | None = None) -> None:
    payload = {
        "enabledUntilEpochSeconds": time.time() + 600,
        "filter": args.scenario if scenario_filter is None else scenario_filter,
        "baseURL": args.base_url,
        "handleA": args.handle_a,
        "handleB": args.handle_b,
        "deviceIDA": args.device_id_a,
        "deviceIDB": args.device_id_b,
        "controlCommandTransportPolicy": args.control_command_transport_policy or None,
        "scenarioFile": args.scenario_file,
        "scenarioDirectory": args.scenario_directory,
    }
    path.write_text(json.dumps(payload), encoding="utf-8")


def base_url_is_local(value: str) -> bool:
    host = (urlparse(value).hostname or "").lower()
    return host in {"localhost", "127.0.0.1", "::1"}


def checked_in_scenario_names(args: argparse.Namespace, repo_root: Path) -> list[str] | None:
    if args.scenario_file or args.scenario_directory:
        return None

    scenario_dir = repo_root / "shared" / "scenarios"
    requested = [
        name.strip()
        for name in args.scenario.split(",")
        if name.strip()
    ]
    requested_set = set(requested)
    names: list[str] = []
    local_only_mismatches: list[str] = []

    for path in sorted(scenario_dir.glob("*.json")):
        spec = json.loads(path.read_text(encoding="utf-8"))
        name = str(spec.get("name") or path.stem)
        if requested_set and name not in requested_set:
            continue
        requires_local = spec.get("requiresLocalBackend") is True
        if requires_local and not base_url_is_local(args.base_url):
            local_only_mismatches.append(name)
            continue
        names.append(name)

    missing = [name for name in requested if name not in set(names) and name not in set(local_only_mismatches)]
    if missing:
        raise RuntimeError(f"No simulator scenarios matched filter {','.join(missing)}")
    if requested and local_only_mismatches:
        raise RuntimeError(f"Scenario(s) require a local backend: {', '.join(local_only_mismatches)}")
    if not names:
        raise RuntimeError(f"No runnable simulator scenarios found in {scenario_dir}")
    return names


def run_command(command: list[str]) -> tuple[int, str]:
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
        sys.stdout.write(line)
        sys.stdout.flush()
        collected.append(line)
    return process.wait(), "".join(collected)


def is_transient_failure(output: str, exit_code: int) -> bool:
    if exit_code == 0:
        return False
    normalized = output.lower()
    return any(marker.lower() in normalized for marker in TRANSIENT_FAILURE_MARKERS)


def transient_failure_device_ids(output: str) -> list[str]:
    ids = re.findall(
        r"(?:RUN_DESTINATION_DEVICE_UDID|device_identifier)\"?\s*[=:]\s*\"?([0-9A-Fa-f-]{36})",
        output,
    )
    return list(dict.fromkeys(ids))


def recover_simulator_after_transient_failure(output: str) -> None:
    device_ids = transient_failure_device_ids(output)
    targets = device_ids if device_ids else ["all"]
    subprocess.run(
        ["xcrun", "simctl", "shutdown", *targets],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if device_ids:
        subprocess.run(
            ["xcrun", "simctl", "erase", *device_ids],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


def run_with_retries(command: list[str], args: argparse.Namespace) -> int:
    last_exit_code = 1
    for attempt in range(1, args.max_attempts + 1):
        if attempt > 1:
            print(f"Retrying simulator scenario run (attempt {attempt}/{args.max_attempts}) after transient failure...", flush=True)
        last_exit_code, output = run_command(command)
        if last_exit_code == 0:
            return 0
        if not is_transient_failure(output, last_exit_code):
            return last_exit_code
        if attempt < args.max_attempts:
            recover_simulator_after_transient_failure(output)
            time.sleep(args.retry_delay_seconds)
    return last_exit_code


def run_catalog_scenario_with_retries(command: list[str], args: argparse.Namespace, scenario_name: str) -> int:
    last_exit_code = 1
    max_attempts = max(1, args.catalog_scenario_attempts)
    for attempt in range(1, max_attempts + 1):
        if attempt > 1:
            print(
                f"Retrying simulator scenario {scenario_name} "
                f"(attempt {attempt}/{max_attempts}) after isolated catalog failure...",
                flush=True,
            )
            time.sleep(args.retry_delay_seconds)
        last_exit_code = run_with_retries(command, args)
        if last_exit_code == 0:
            return 0
    return last_exit_code


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    else:
        return True


@contextmanager
def acquire_pid_lock(lock_path: Path):
    while True:
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            with os.fdopen(fd, "w", encoding="utf-8") as lock_file:
                lock_file.write(f"{os.getpid()}\n")
            break
        except FileExistsError:
            try:
                lock_pid = int(lock_path.read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                lock_pid = 0
            if lock_pid == 0:
                lock_path.unlink(missing_ok=True)
                continue
            if lock_pid and not process_exists(lock_pid):
                lock_path.unlink(missing_ok=True)
                continue
            time.sleep(0.2)

    try:
        yield
    finally:
        lock_path.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    lock_path = repo_root / args.lock_file
    simulator_lock_path = Path(args.simulator_lock_file)
    runtime_config_path = repo_root / args.runtime_config

    with acquire_pid_lock(simulator_lock_path):
        with lock_path.open("w", encoding="utf-8") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                command = [
                    "xcodebuild",
                    "-project", args.project,
                    "-scheme", args.scheme,
                    "-destination", args.destination,
                    "-only-testing:TurboTests/SimulatorScenarioTests",
                    "-skip-testing:TurboUITests",
                    "-parallel-testing-enabled", "NO",
                    "-maximum-concurrent-test-simulator-destinations", "1",
                    "-maximum-parallel-testing-workers", "1",
                    "-derivedDataPath", args.derived_data,
                    "test",
                    "CODE_SIGNING_ALLOWED=NO",
                ]

                scenario_names = checked_in_scenario_names(args, repo_root)
                if scenario_names is None:
                    write_runtime_config(runtime_config_path, args)
                    return run_with_retries(command, args)

                for index, scenario_name in enumerate(scenario_names, start=1):
                    print(f"Running simulator scenario {index}/{len(scenario_names)}: {scenario_name}", flush=True)
                    write_runtime_config(runtime_config_path, args, scenario_filter=scenario_name)
                    exit_code = run_catalog_scenario_with_retries(command, args, scenario_name)
                    if exit_code != 0:
                        return exit_code
                return 0
            finally:
                try:
                    runtime_config_path.unlink()
                except FileNotFoundError:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
