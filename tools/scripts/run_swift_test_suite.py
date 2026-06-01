#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from run_targeted_swift_tests import (
    acquire_lock,
    ensure_simulator_ready,
    recover_simulator,
    resolve_simulator_destination,
    run_xcodebuild,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the full TurboTests Swift test bundle and fail if zero tests executed."
    )
    parser.add_argument("--project", default="client/ios/Turbo.xcodeproj")
    parser.add_argument("--scheme", default="BeepBeep")
    parser.add_argument("--destination", default="platform=iOS Simulator,name=iPhone 17")
    parser.add_argument("--derived-data", default="")
    parser.add_argument("--lock-file", default="/tmp/turbo-simulator-test.lock")
    parser.add_argument("--result-bundle-path", default="/tmp/turbo-swift-test-suite.xcresult")
    return parser.parse_args()


def build_xcodebuild_command(args: argparse.Namespace, destination: str) -> list[str]:
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
            "-resultBundlePath", args.result_bundle_path,
            "-only-testing:TurboTests",
            "-skip-testing:TurboUITests",
            "-parallel-testing-enabled", "NO",
            "-maximum-concurrent-test-simulator-destinations", "1",
            "-maximum-parallel-testing-workers", "1",
            "test",
            "CODE_SIGNING_ALLOWED=NO",
        ]
    )
    return command


def total_test_count(result_bundle_path: str) -> int:
    summary = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            result_bundle_path,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    payload = json.loads(summary.stdout)
    top_level_total = payload.get("totalTestCount")
    if top_level_total is not None:
        return int(top_level_total)

    return int(payload.get("devicesAndConfigurations", [{}])[0].get("totalTestCount", 0))


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    lock_path = repo_root / args.lock_file
    result_bundle_path = Path(args.result_bundle_path)

    with acquire_lock(lock_path):
        destination, simulator_udid = resolve_simulator_destination(args.destination)
        if simulator_udid:
            print(
                f"swift-test-suite: preparing simulator {simulator_udid}",
                file=sys.stderr,
            )
            ensure_simulator_ready(simulator_udid)

        if result_bundle_path.exists():
            if result_bundle_path.is_dir():
                shutil.rmtree(result_bundle_path)
            else:
                result_bundle_path.unlink()

        command = build_xcodebuild_command(args, destination)
        exit_code, saw_launch_preflight_failure = run_xcodebuild(command, {})

        if exit_code != 0 and saw_launch_preflight_failure and simulator_udid:
            recover_simulator(simulator_udid)
            exit_code, _ = run_xcodebuild(command, {})

        if exit_code != 0:
            return exit_code

        try:
            test_count = total_test_count(args.result_bundle_path)
        except subprocess.CalledProcessError as exc:
            print(exc.stdout, file=sys.stderr, end="")
            print(exc.stderr, file=sys.stderr, end="")
            return exc.returncode

        if test_count <= 0:
            print(
                "Swift test suite executed zero tests according to xcresult summary.",
                file=sys.stderr,
            )
            return 1

        print(f"swift-test-suite: xcresult reported {test_count} tests executed", file=sys.stderr)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
