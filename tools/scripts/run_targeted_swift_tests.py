#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run targeted Turbo Swift Testing tests and fail if the requested test names do not execute."
    )
    parser.add_argument(
        "--name",
        action="append",
        dest="names",
        required=True,
        help="Exact Swift test function name to require in the output. May be repeated.",
    )
    parser.add_argument("--project", default="client/ios/Turbo.xcodeproj")
    parser.add_argument("--scheme", default="BeepBeep")
    parser.add_argument("--test-target", default="TurboTests")
    parser.add_argument("--test-source-dir", default="TurboTests")
    parser.add_argument("--destination", default="platform=iOS Simulator,name=iPhone 17")
    parser.add_argument(
        "--derived-data",
        default="",
        help="Optional DerivedData path. By default Xcode's normal incremental DerivedData is reused.",
    )
    parser.add_argument("--lock-file", default="/tmp/turbo-simulator-test.lock")
    return parser.parse_args()


def parse_destination(destination: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for part in destination.split(","):
        key, separator, value = part.partition("=")
        if separator:
            fields[key.strip()] = value.strip()
    return fields


def parse_runtime_version(runtime: str) -> tuple[int, ...]:
    version = runtime.rsplit("iOS-", 1)[-1].replace("-", ".")
    return tuple(int(part) for part in version.split(".") if part.isdigit())


def native_simulator_arch() -> str:
    return "arm64" if platform.machine() == "arm64" else "x86_64"


def resolve_simulator_destination(destination: str) -> tuple[str, str | None]:
    fields = parse_destination(destination)
    if fields.get("platform") != "iOS Simulator":
        return destination, None

    arch = fields.get("arch", native_simulator_arch())
    if "id" in fields:
        return f"platform=iOS Simulator,id={fields['id']},arch={arch}", fields["id"]

    name = fields.get("name")
    if not name:
        return destination, None

    requested_os = fields.get("OS")
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True,
        text=True,
        check=True,
    )
    payload = json.loads(result.stdout)
    candidates: list[tuple[tuple[int, ...], int, str]] = []
    for runtime, devices in payload.get("devices", {}).items():
        if "iOS-" not in runtime:
            continue
        runtime_version = parse_runtime_version(runtime)
        runtime_text = ".".join(str(part) for part in runtime_version)
        if requested_os and runtime_text != requested_os:
            continue
        for device in devices:
            if not device.get("isAvailable", False):
                continue
            if device.get("name") != name:
                continue
            state_rank = 0 if device.get("state") == "Booted" else 1
            candidates.append((runtime_version, state_rank, device["udid"]))

    if not candidates:
        return destination, None

    runtime_version, _, udid = sorted(
        candidates,
        key=lambda candidate: (-candidate[0][0],) + tuple(-part for part in candidate[0][1:]) + (candidate[1],),
    )[0]
    version_text = ".".join(str(part) for part in runtime_version)
    return f"platform=iOS Simulator,id={udid},OS={version_text},arch={arch}", udid


def run_simctl(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["xcrun", "simctl", *args],
        capture_output=True,
        text=True,
        check=check,
    )


def ensure_simulator_ready(udid: str) -> None:
    boot = run_simctl("boot", udid, check=False)
    if boot.returncode not in (0, 149):
        raise subprocess.CalledProcessError(
            boot.returncode,
            boot.args,
            output=boot.stdout,
            stderr=boot.stderr,
        )
    run_simctl("bootstatus", udid, "-b")
    run_simctl("terminate", udid, "com.rounded.Turbo", check=False)


def recover_simulator(udid: str) -> None:
    print(
        f"swift-test-target: recovering simulator {udid} after launch preflight failure",
        file=sys.stderr,
    )
    run_simctl("shutdown", udid, check=False)
    time.sleep(1.0)
    ensure_simulator_ready(udid)


def discover_swift_testing_selectors(
    source_dir: Path,
    target: str,
    names: list[str],
) -> tuple[list[str], list[str]]:
    requested = [name.removesuffix("()") for name in names]
    exact_selectors: list[str] = []
    lookup_names: list[str] = []
    unresolved: list[str] = []

    for name in requested:
        if "/" in name:
            selector = name if name.startswith(f"{target}/") else f"{target}/{name}"
            exact_selectors.append(selector if selector.endswith(")") else f"{selector}()")
            lookup_names.append(selector.rsplit("/", 1)[-1].removesuffix("()"))
        else:
            unresolved.append(name)

    if not unresolved:
        return exact_selectors, lookup_names

    tests_by_name: dict[str, list[tuple[str, Path]]] = {}
    type_pattern = re.compile(
        r"^(?:@\w+(?:\([^)]*\))?\s*)*"
        r"(?:public|internal|private|fileprivate)?\s*"
        r"(?:struct|final\s+class|class|actor)\s+(\w+)"
    )
    test_pattern = re.compile(r"@Test(?:\([^)]*\))?\s+func\s+(\w+)")

    for source_path in sorted(source_dir.glob("*.swift")):
        current_suite: str | None = None
        for line in source_path.read_text(encoding="utf-8").splitlines():
            # Swift Testing suites are top-level types. Local helper types inside
            # test functions are indented and must not replace the active suite.
            if line[:1] and not line[:1].isspace():
                type_match = type_pattern.search(line)
                if type_match:
                    current_suite = type_match.group(1)

            test_match = test_pattern.search(line)
            if test_match and current_suite:
                tests_by_name.setdefault(test_match.group(1), []).append(
                    (current_suite, source_path)
                )

    selectors = list(exact_selectors)
    lookup_names.extend(unresolved)
    missing: list[str] = []
    ambiguous: list[str] = []
    for name in unresolved:
        matches = tests_by_name.get(name, [])
        if not matches:
            missing.append(name)
            continue
        if len(matches) > 1:
            ambiguous.append(
                f"{name} ({', '.join(f'{suite} in {path}' for suite, path in matches)})"
            )
            continue
        suite, _ = matches[0]
        selectors.append(f"{target}/{suite}/{name}()")

    if missing or ambiguous:
        if missing:
            print(
                "Could not find Swift Testing functions: " + ", ".join(missing),
                file=sys.stderr,
            )
        if ambiguous:
            print(
                "Ambiguous Swift Testing function names; pass an exact selector: "
                + "; ".join(ambiguous),
                file=sys.stderr,
            )
        raise SystemExit(1)

    return selectors, lookup_names


def build_xcodebuild_command(
    args: argparse.Namespace,
    destination: str,
    selectors: list[str],
) -> list[str]:
    command = [
        "xcodebuild",
        "-project", args.project,
        "-scheme", args.scheme,
        "-destination", destination,
    ]
    if args.derived_data:
        command.extend(["-derivedDataPath", args.derived_data])
    command.extend(
        [
            *[f"-only-testing:{selector}" for selector in selectors],
            "-skip-testing:TurboUITests",
            "-parallel-testing-enabled", "NO",
            "-maximum-concurrent-test-simulator-destinations", "1",
            "-maximum-parallel-testing-workers", "1",
            "test",
            "CODE_SIGNING_ALLOWED=NO",
        ]
    )
    return command


def run_xcodebuild(command: list[str], seen: dict[str, bool]) -> tuple[int, bool]:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    saw_launch_preflight_failure = False
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        if (
            "Application failed preflight checks" in line
            or "Simulator device failed to launch" in line
        ):
            saw_launch_preflight_failure = True
        for name in seen:
            if f"Test {name}()" in line:
                seen[name] = True

    return process.wait(), saw_launch_preflight_failure


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
def acquire_lock(lock_path: Path):
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


@contextmanager
def expose_audio_incident_corpus_path():
    corpus_path = os.environ.get("TURBO_AUDIO_INCIDENT_CORPUS_PATH", "").strip()
    if not corpus_path:
        yield
        return
    corpus_path = str(Path(corpus_path).expanduser().resolve())

    marker_path = Path("/tmp/turbo-audio-incident-corpus-path")
    marker_path.write_text(corpus_path + "\n", encoding="utf-8")
    try:
        yield
    finally:
        try:
            if marker_path.read_text(encoding="utf-8").strip() == corpus_path:
                marker_path.unlink(missing_ok=True)
        except OSError:
            pass


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    lock_path = repo_root / args.lock_file
    selectors, lookup_names = discover_swift_testing_selectors(
        repo_root / args.test_source_dir,
        args.test_target,
        args.names,
    )

    with acquire_lock(lock_path), expose_audio_incident_corpus_path():
        destination, simulator_udid = resolve_simulator_destination(args.destination)
        if simulator_udid:
            print(
                f"swift-test-target: preparing simulator {simulator_udid}",
                file=sys.stderr,
            )
            ensure_simulator_ready(simulator_udid)

        command = build_xcodebuild_command(args, destination, selectors)
        seen = {name: False for name in lookup_names}
        exit_code, saw_launch_preflight_failure = run_xcodebuild(command, seen)

        if exit_code != 0 and saw_launch_preflight_failure and simulator_udid:
            recover_simulator(simulator_udid)
            exit_code, _ = run_xcodebuild(command, seen)

        missing = [name for name, was_seen in seen.items() if not was_seen]
        if missing:
            print(
                "Requested Swift tests did not execute: " + ", ".join(missing),
                file=sys.stderr,
            )
            return 1
        return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
