#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_OUTPUT_DIR = Path("/tmp/turbo-protocol-model-checks")
DEFAULT_SPEC_DIR = Path("shared/specs/tla")
DEFAULT_TLA_JAR = Path(os.environ.get("TLA2TOOLS_JAR", "/tmp/tla2tools.jar"))
DEFAULT_SWIFT_PROPERTY_TESTS = (
    "conversationProjectionProperties",
    "transportFaultPlannerProperties",
)
TURBO_COMMUNICATION_REQUIRED_TLA_INVARIANTS = (
    "TypeOK",
    "DirectChannelCardinality",
    "RequestEndpointsAreValid",
    "PendingRequestHasNoMembership",
    "LocalJoinIntentRequiresMembership",
    "WakeTokenRequiresMembership",
    "ReceiverReadyRequiresJoinedPresence",
    "ActiveTransmitterIsJoinedMember",
    "ActiveTransmitHasAddressableReceiver",
    "BeginTransmitRequiresAcceptedOrExplicitMembership",
    "ActiveTransmitRequiresBothDirectMembers",
    "ReceivingHasLocalTransmitEvidence",
    "TransmittingHasLocalTransmitEvidence",
    "DisconnectedClientIsNotLive",
    "StaleMembershipWithoutLocalEvidenceIsNotJoining",
    "NotJoinedProjectionHasNoLocalJoinIntent",
)
TURBO_SESSION_GENERATION_REQUIRED_TLA_INVARIANTS = (
    "TypeOK",
    "JoinedPresenceUsesCurrentSession",
    "ActiveChannelUsesCurrentSession",
    "ReceiverReadyUsesCurrentSession",
    "ActiveTransmitterUsesCurrentSession",
)
TURBO_TALK_TURN_ACTOR_REQUIRED_TLA_INVARIANTS = (
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
)
REQUIRED_TLA_INVARIANTS_BY_MODULE = {
    "TurboCommunication": TURBO_COMMUNICATION_REQUIRED_TLA_INVARIANTS,
    "TurboSessionGeneration": TURBO_SESSION_GENERATION_REQUIRED_TLA_INVARIANTS,
    "TurboTalkTurnActor": TURBO_TALK_TURN_ACTOR_REQUIRED_TLA_INVARIANTS,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run Turbo core communication protocol model checks and Swift property tests."
    )
    parser.add_argument("--spec-dir", default=str(DEFAULT_SPEC_DIR))
    parser.add_argument("--module", default="TurboCommunication")
    parser.add_argument("--config", default="TurboCommunication.cfg")
    parser.add_argument("--tla-jar", default=str(DEFAULT_TLA_JAR))
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR))
    parser.add_argument("--tlc-timeout", type=int, default=900)
    parser.add_argument("--skip-tlc", action="store_true")
    parser.add_argument("--skip-swift-properties", action="store_true")
    parser.add_argument("--swift-test-name", action="append", default=[])
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    spec_dir = Path(args.spec_dir)
    spec_path = spec_dir / f"{args.module}.tla"
    config_path = spec_dir / args.config
    steps: list[dict[str, Any]] = []

    print("protocol-model-check: validating TLA+ spec/config", flush=True)
    validation = validate_tla_config(spec_path, config_path)
    steps.append({"name": "tla-config-validation", **validation})

    if not args.skip_tlc:
        print("protocol-model-check: running TLC", flush=True)
        tlc_result = run_tlc(
            spec_dir=spec_dir,
            module=args.module,
            config=args.config,
            tla_jar=Path(args.tla_jar),
            output_path=output_dir / "tlc-output.txt",
            timeout=args.tlc_timeout,
        )
        steps.append({"name": "tlc", **tlc_result})

    swift_test_names = tuple(args.swift_test_name or DEFAULT_SWIFT_PROPERTY_TESTS)
    if not args.skip_swift_properties:
        print("protocol-model-check: running Swift property tests", flush=True)
        swift_result = run_swift_properties(
            repo_root=repo_root,
            names=swift_test_names,
            output_path=output_dir / "swift-property-tests-output.txt",
        )
        steps.append({"name": "swift-property-tests", **swift_result})

    ok = all(step.get("ok") is True for step in steps)
    summary = {
        "schemaVersion": 1,
        "ok": ok,
        "status": "pass" if ok else "fail",
        "generatedAt": utc_now(),
        "spec": str(spec_path),
        "config": str(config_path),
        "tlaJar": None if args.skip_tlc else str(Path(args.tla_jar)),
        "swiftPropertyTests": [] if args.skip_swift_properties else list(swift_test_names),
        "steps": steps,
        "reproduceCommand": str(output_dir / "reproduce.sh"),
    }
    write_json(output_dir / "protocol-model-checks.json", summary)
    write_reproduce_script(output_dir, args)
    print(f"protocol-model-check status: {summary['status']}", flush=True)
    print(f"protocol-model-check artifacts: {output_dir}", flush=True)
    return 0 if ok else 1


def validate_tla_config(spec_path: Path, config_path: Path) -> dict[str, Any]:
    if not spec_path.exists():
        raise SystemExit(f"missing TLA+ spec: {spec_path}")
    if not config_path.exists():
        raise SystemExit(f"missing TLA+ config: {config_path}")

    spec_text = spec_path.read_text(encoding="utf-8")
    config_text = config_path.read_text(encoding="utf-8")
    defined_operators = set(re.findall(r"^([A-Za-z][A-Za-z0-9_]*)\s*==", spec_text, re.MULTILINE))
    configured_invariants = parse_configured_invariants(config_text)
    missing_definitions = sorted(name for name in configured_invariants if name not in defined_operators)
    required_invariants = REQUIRED_TLA_INVARIANTS_BY_MODULE.get(spec_path.stem, ())
    missing_required = sorted(name for name in required_invariants if name not in configured_invariants)
    has_specification = "SPECIFICATION Spec" in config_text and "Spec ==" in spec_text
    ok = not missing_definitions and not missing_required and has_specification
    return {
        "ok": ok,
        "configuredInvariantCount": len(configured_invariants),
        "configuredInvariants": configured_invariants,
        "missingDefinitions": missing_definitions,
        "missingRequiredInvariants": missing_required,
        "hasSpecification": has_specification,
    }


def parse_configured_invariants(config_text: str) -> list[str]:
    invariants: list[str] = []
    in_block = False
    for raw_line in config_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line == "INVARIANTS":
            in_block = True
            continue
        if not in_block:
            continue
        if re.match(r"^[A-Z_]+(\s|$)", line):
            break
        if re.match(r"^[A-Za-z][A-Za-z0-9_]*$", line):
            invariants.append(line)
    return invariants


def run_tlc(
    *,
    spec_dir: Path,
    module: str,
    config: str,
    tla_jar: Path,
    output_path: Path,
    timeout: int,
) -> dict[str, Any]:
    if not tla_jar.exists():
        return {
            "ok": False,
            "error": f"missing tla2tools jar: {tla_jar}",
            "outputPath": str(output_path),
        }

    command = [
        "java",
        "-cp",
        str(tla_jar),
        "tlc2.TLC",
        "-deadlock",
        "-config",
        config,
        f"{module}.tla",
    ]
    completed = subprocess.run(
        command,
        cwd=spec_dir,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    output = completed.stdout + completed.stderr
    output_path.write_text(output, encoding="utf-8")
    ok = completed.returncode == 0 and "No error has been found" in output
    return {
        "ok": ok,
        "exitCode": completed.returncode,
        "command": command,
        "outputPath": str(output_path),
        "summary": extract_tlc_summary(output),
    }


def extract_tlc_summary(output: str) -> list[str]:
    interesting = []
    for line in output.splitlines():
        if (
            "states generated" in line
            or "distinct states found" in line
            or "states left on queue" in line
            or "No error has been found" in line
            or "Error:" in line
        ):
            interesting.append(line.strip())
    return interesting[-12:]


def run_swift_properties(*, repo_root: Path, names: tuple[str, ...], output_path: Path) -> dict[str, Any]:
    command = [sys.executable, "tools/scripts/run_targeted_swift_tests.py"]
    for name in names:
        command.extend(["--name", name])

    with output_path.open("w", encoding="utf-8") as output_file:
        completed = subprocess.run(
            command,
            cwd=repo_root,
            stdout=output_file,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    output = output_path.read_text(encoding="utf-8", errors="replace")
    missing = [name for name in names if f"Test {name}()" not in output]
    ok = completed.returncode == 0 and not missing
    return {
        "ok": ok,
        "exitCode": completed.returncode,
        "command": command,
        "outputPath": str(output_path),
        "requiredTests": list(names),
        "missingTests": missing,
    }


def write_reproduce_script(output_dir: Path, args: argparse.Namespace) -> None:
    command = [
        sys.executable,
        "tools/scripts/protocol_model_check.py",
        "--spec-dir",
        args.spec_dir,
        "--module",
        args.module,
        "--config",
        args.config,
        "--tla-jar",
        args.tla_jar,
        "--output-dir",
        str(output_dir),
        "--tlc-timeout",
        str(args.tlc_timeout),
    ]
    if args.skip_tlc:
        command.append("--skip-tlc")
    if args.skip_swift_properties:
        command.append("--skip-swift-properties")
    for name in args.swift_test_name:
        command.extend(["--swift-test-name", name])

    script = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f"cd {shell_quote(str(Path.cwd()))}\n"
        + " ".join(shell_quote(part) for part in command)
        + "\n"
    )
    path = output_dir / "reproduce.sh"
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    raise SystemExit(main())
