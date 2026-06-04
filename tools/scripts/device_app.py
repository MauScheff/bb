#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shutil
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from run_targeted_swift_tests import discover_swift_testing_selectors


DEFAULT_PROJECT = "client/ios/Turbo.xcodeproj"
DEFAULT_SCHEME = "BeepBeep"
DEFAULT_CONFIGURATION = "Debug"
DEFAULT_BUNDLE_ID = "com.rounded.Turbo"
DEFAULT_DERIVED_DATA = "/tmp/turbo-device-derived-data"
DEFAULT_ARTIFACT_DIR = "/tmp/turbo-device-app"


@dataclass(frozen=True)
class Device:
    identifier: str
    udid: str
    name: str
    model: str
    os_version: str
    state: str
    transport: str
    serial_number: str
    developer_mode: str

    @property
    def devicectl_identifier(self) -> str:
        return self.identifier or self.udid

    @property
    def xcodebuild_identifier(self) -> str:
        return self.udid or self.identifier


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build, install, launch, and test Turbo on connected physical iOS devices."
    )
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--scheme", default=DEFAULT_SCHEME)
    parser.add_argument("--configuration", default=DEFAULT_CONFIGURATION)
    parser.add_argument("--derived-data", default=DEFAULT_DERIVED_DATA)
    parser.add_argument("--bundle-id", dest="default_bundle_id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--timeout", default="60")
    parser.add_argument("--artifact-dir", default=DEFAULT_ARTIFACT_DIR)

    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="List connected physical iOS devices.")
    list_parser.add_argument("--json", action="store_true", help="Print parsed JSON instead of a table.")

    info_parser = subparsers.add_parser("info", help="Print devicectl details for a device.")
    add_device_arg(info_parser)

    lock_state_parser = subparsers.add_parser("lock-state", help="Print devicectl lock-state details for a device.")
    add_device_arg(lock_state_parser)
    lock_state_parser.add_argument("--json", action="store_true", help="Print parsed JSON instead of the devicectl text output.")

    lock_state_connected_parser = subparsers.add_parser(
        "lock-state-connected",
        help="Collect devicectl lock-state details from every paired physical iOS device.",
    )
    lock_state_connected_parser.add_argument("--json", action="store_true", help="Print parsed JSON instead of a table.")

    build_parser = subparsers.add_parser("build", help="Build the app for a connected device.")
    add_device_arg(build_parser)

    install_parser = subparsers.add_parser("install", help="Install an existing app path or build then install.")
    add_device_arg(install_parser)
    install_parser.add_argument("--app-path", default="")

    launch_parser = subparsers.add_parser("launch", help="Launch the app on a connected device.")
    add_device_arg(launch_parser)
    add_launch_args(launch_parser)

    launch_connected_parser = subparsers.add_parser(
        "launch-connected",
        help="Launch the already-installed app once per connected physical iOS device.",
    )
    add_launch_args(launch_connected_parser)
    launch_connected_parser.add_argument(
        "--continue-on-device-error",
        action="store_true",
        help="Attempt every connected device and report all per-device failures before exiting nonzero.",
    )
    launch_connected_parser.add_argument("--json", action="store_true", help="Print per-device launch results as JSON.")
    launch_connected_parser.add_argument(
        "--output",
        default="",
        help="Optional path to write the JSON launchability results. Implies --json.",
    )

    run_parser = subparsers.add_parser("run", help="Build, install, and launch the app.")
    add_device_arg(run_parser)
    add_launch_args(run_parser)

    run_connected_parser = subparsers.add_parser(
        "run-connected",
        help="Build, install, and launch once per connected physical iOS device.",
    )
    add_launch_args(run_connected_parser)
    run_connected_parser.add_argument(
        "--continue-on-device-error",
        action="store_true",
        help="Attempt every connected device and report all per-device failures before exiting nonzero.",
    )

    diagnostics_parser = subparsers.add_parser(
        "diagnostics",
        help="Extract app diagnostics from one connected physical iOS device.",
    )
    add_device_arg(diagnostics_parser)
    add_diagnostics_args(diagnostics_parser)

    diagnostics_connected_parser = subparsers.add_parser(
        "diagnostics-connected",
        help="Extract app diagnostics from every connected physical iOS device.",
    )
    add_diagnostics_args(diagnostics_connected_parser)

    sysdiagnose_parser = subparsers.add_parser(
        "sysdiagnose",
        help="Gather a device sysdiagnose. This can be slow and large.",
    )
    add_device_arg(sysdiagnose_parser)
    sysdiagnose_parser.add_argument("--output-dir", default="")
    sysdiagnose_parser.add_argument("--gather-full-logs", action="store_true")
    sysdiagnose_parser.add_argument("--dry-run", action="store_true")

    test_parser = subparsers.add_parser("test", help="Run xcodebuild tests on a connected device.")
    add_device_arg(test_parser)
    test_parser.add_argument(
        "--only-testing",
        action="append",
        default=[],
        help="xcodebuild only-testing selector. Defaults to TurboTests when --name is not used.",
    )
    test_parser.add_argument(
        "--skip-testing",
        action="append",
        default=[],
        help="xcodebuild skip-testing selector. Defaults to TurboUITests when --name is not used.",
    )
    test_parser.add_argument(
        "--name",
        action="append",
        default=[],
        help="Swift Testing function name to resolve and require in output. May be repeated.",
    )
    test_parser.add_argument("--test-target", default="TurboTests")
    test_parser.add_argument("--test-source-dir", default="TurboTests")
    test_parser.add_argument("--result-bundle-path", default="")

    return parser.parse_args(argv)


def parse_args_for_test(argv: list[str]) -> argparse.Namespace:
    return parse_args(argv)


def add_device_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--device",
        default="",
        help="Device identifier, hardware UDID, serial number, or exact device name. Empty is allowed only with one connected physical iOS device.",
    )


def add_launch_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bundle-id", dest="launch_bundle_id", default="", help="Bundle id to launch. Defaults to the global bundle id.")
    parser.add_argument("--terminate-existing", action="store_true")
    parser.add_argument("--console", action="store_true")
    parser.add_argument("--start-stopped", action="store_true")
    parser.add_argument("--no-activate", action="store_true")
    parser.add_argument(
        "--env",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Environment variable passed to the launched process.",
    )
    parser.add_argument(
        "launch_args",
        nargs=argparse.REMAINDER,
        help="Arguments passed to the launched app. Prefix with -- when needed.",
    )


def add_diagnostics_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bundle-id", dest="diagnostics_bundle_id", default="")
    parser.add_argument("--output-dir", default="")
    parser.add_argument("--include-crash-logs", action="store_true")
    parser.add_argument("--include-sysdiagnose", action="store_true")
    parser.add_argument("--tail-bytes", type=int, default=1_048_576)
    parser.add_argument("--dry-run", action="store_true")


def run(command: list[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    print("+ " + shlex.join(command), file=sys.stderr)
    return subprocess.run(command, text=True, env=env)


def run_captured(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True)


def run_maybe_dry(command: list[str], dry_run: bool) -> subprocess.CompletedProcess[str]:
    print("+ " + shlex.join(command), file=sys.stderr)
    if dry_run:
        return subprocess.CompletedProcess(command, 0)
    return subprocess.run(command, text=True)


def timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def artifact_path(args: argparse.Namespace, stem: str, suffix: str) -> Path:
    directory = Path(args.artifact_dir)
    directory.mkdir(parents=True, exist_ok=True)
    return directory / f"{timestamp()}-{stem}.{suffix}"


def devicectl_json(args: argparse.Namespace, *devicectl_args: str) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="turbo-devicectl-") as temp_dir:
        output_path = Path(temp_dir) / "output.json"
        command = [
            "xcrun",
            "devicectl",
            "--timeout",
            str(args.timeout),
            "--json-output",
            str(output_path),
            *devicectl_args,
        ]
        result = run_captured(command)
        if result.returncode != 0:
            if result.stdout:
                print(result.stdout, end="")
            if result.stderr:
                print(result.stderr, file=sys.stderr, end="")
            raise subprocess.CalledProcessError(
                result.returncode,
                command,
                output=result.stdout,
                stderr=result.stderr,
            )
        return json.loads(output_path.read_text(encoding="utf-8"))


def connected_devices(args: argparse.Namespace) -> list[Device]:
    payload = devicectl_json(args, "list", "devices")
    raw_devices = payload.get("result", {}).get("devices", [])  # type: ignore[union-attr]
    devices: list[Device] = []
    for raw in raw_devices:
        if not isinstance(raw, dict):
            continue
        hardware = raw.get("hardwareProperties", {})
        device_properties = raw.get("deviceProperties", {})
        connection = raw.get("connectionProperties", {})
        if not isinstance(hardware, dict) or not isinstance(device_properties, dict) or not isinstance(connection, dict):
            continue
        if hardware.get("platform") != "iOS":
            continue
        if hardware.get("reality") != "physical":
            continue
        if connection.get("pairingState") not in {None, "", "paired"}:
            continue
        tunnel_state = str(connection.get("tunnelState") or "")
        devices.append(
            Device(
                identifier=str(raw.get("identifier") or ""),
                udid=str(hardware.get("udid") or ""),
                name=str(device_properties.get("name") or ""),
                model=str(hardware.get("marketingName") or hardware.get("productType") or ""),
                os_version=str(device_properties.get("osVersionNumber") or ""),
                state=tunnel_state or "available",
                transport=str(connection.get("transportType") or ""),
                serial_number=str(hardware.get("serialNumber") or ""),
                developer_mode=str(device_properties.get("developerModeStatus") or ""),
            )
        )
    return devices


def print_devices(devices: list[Device]) -> None:
    if not devices:
        print("No available paired physical iOS devices found.")
        return
    headers = ["Name", "UDID", "devicectl ID", "OS", "Model", "Transport", "State"]
    rows = [
        [device.name, device.udid, device.identifier, device.os_version, device.model, device.transport, device.state]
        for device in devices
    ]
    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))
    print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(value.ljust(widths[index]) for index, value in enumerate(row)))


def normalize(value: str) -> str:
    return value.casefold().strip()


def resolve_device(args: argparse.Namespace) -> Device:
    devices = connected_devices(args)
    requested = normalize(args.device)
    if not requested:
        if len(devices) == 1:
            return devices[0]
        print_devices(devices)
        if devices:
            raise SystemExit("Multiple connected physical iOS devices found; pass --device <UDID-or-name>.")
        raise SystemExit("No available paired physical iOS devices found.")

    matches: list[Device] = []
    for device in devices:
        candidates = [
            device.identifier,
            device.udid,
            device.name,
            device.serial_number,
        ]
        if requested in {normalize(candidate) for candidate in candidates if candidate}:
            matches.append(device)

    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        print_devices(matches)
        raise SystemExit(f"Device selector matched multiple devices: {args.device}")

    print_devices(devices)
    raise SystemExit(f"Available paired physical iOS device not found: {args.device}")


def xcode_destination(device: Device) -> str:
    return f"platform=iOS,id={device.xcodebuild_identifier}"


def signing_update_flags() -> list[str]:
    enabled = os.environ.get("TURBO_DEVICE_ALLOW_PROVISIONING_UPDATES", "")
    return ["-allowProvisioningUpdates"] if enabled in {"1", "true", "TRUE", "yes", "YES"} else []


def build_settings(args: argparse.Namespace, device: Device) -> dict[str, str]:
    command = [
        "xcodebuild",
        "-project",
        args.project,
        "-scheme",
        args.scheme,
        "-configuration",
        args.configuration,
        "-destination",
        xcode_destination(device),
        "-derivedDataPath",
        args.derived_data,
        *signing_update_flags(),
        "-showBuildSettings",
        "-json",
    ]
    print("+ " + shlex.join(command), file=sys.stderr)
    result = run_captured(command)
    if result.returncode != 0:
        print(result.stdout, end="")
        print(result.stderr, file=sys.stderr, end="")
        raise SystemExit(result.returncode)
    payload = json.loads(result.stdout)
    for item in payload:
        settings = item.get("buildSettings", {})
        if settings.get("WRAPPER_EXTENSION") == "app":
            return settings
    raise SystemExit("Could not resolve app build settings from xcodebuild.")


def resolve_app_path(args: argparse.Namespace, device: Device) -> Path:
    settings = build_settings(args, device)
    product_dir = Path(settings["BUILT_PRODUCTS_DIR"])
    product_name = settings["FULL_PRODUCT_NAME"]
    return product_dir / product_name


def build_app(args: argparse.Namespace, device: Device) -> Path:
    command = [
        "xcodebuild",
        "-project",
        args.project,
        "-scheme",
        args.scheme,
        "-configuration",
        args.configuration,
        "-destination",
        xcode_destination(device),
        "-derivedDataPath",
        args.derived_data,
        *signing_update_flags(),
        "build",
    ]
    result = run(command)
    if result.returncode != 0:
        raise SystemExit(result.returncode)
    app_path = resolve_app_path(args, device)
    if not app_path.exists():
        raise SystemExit(f"Built app was not found at {app_path}")
    print(app_path)
    return app_path


def install_app(args: argparse.Namespace, device: Device, app_path: Path) -> None:
    if not app_path.exists():
        raise SystemExit(f"App path does not exist: {app_path}")
    output = artifact_path(args, "install", "json")
    command = [
        "xcrun",
        "devicectl",
        "--timeout",
        str(args.timeout),
        "--json-output",
        str(output),
        "device",
        "install",
        "app",
        "--device",
        device.devicectl_identifier,
        str(app_path),
    ]
    result = run(command)
    print(f"devicectl install JSON: {output}", file=sys.stderr)
    if result.returncode != 0:
        raise SystemExit(result.returncode)


def parse_environment(raw_values: list[str]) -> dict[str, str]:
    environment: dict[str, str] = {}
    for raw_value in raw_values:
        key, separator, value = raw_value.partition("=")
        if not separator or not key:
            raise SystemExit(f"Expected --env KEY=VALUE, got: {raw_value}")
        environment[key] = value
    return environment


def normalized_launch_args(raw_args: list[str]) -> list[str]:
    if raw_args and raw_args[0] == "--":
        return raw_args[1:]
    return raw_args


def launch_app(args: argparse.Namespace, device: Device) -> None:
    output = artifact_path(args, "launch", "json")
    command = launch_app_command(args, device, output)
    result = run(command)
    print(f"devicectl launch JSON: {output}", file=sys.stderr)
    if result.returncode != 0:
        raise SystemExit(result.returncode)


def launch_app_command(args: argparse.Namespace, device: Device, output: Path) -> list[str]:
    bundle_id = args.launch_bundle_id or args.default_bundle_id
    command = [
        "xcrun",
        "devicectl",
        "--timeout",
        str(args.timeout),
        "--json-output",
        str(output),
        "device",
        "process",
        "launch",
        "--device",
        device.devicectl_identifier,
    ]
    if args.terminate_existing:
        command.append("--terminate-existing")
    if args.console:
        command.append("--console")
    if args.start_stopped:
        command.append("--start-stopped")
    if args.no_activate:
        command.append("--no-activate")
    launch_environment = parse_environment(args.env)
    if launch_environment:
        command.extend(["--environment-variables", json.dumps(launch_environment, sort_keys=True)])
    command.append(bundle_id)
    command.extend(normalized_launch_args(args.launch_args))
    return command


def launch_probe_for_device(args: argparse.Namespace, device: Device) -> dict[str, object]:
    output = artifact_path(args, f"launch-{safe_path_component(device.name or device.udid)}", "json")
    command = launch_app_command(args, device, output)
    result = run_captured(command)
    launch_diagnostics = launch_json_diagnostic_text(output)
    reason = classify_launch_result(
        result.returncode,
        result.stdout,
        result.stderr,
        launch_diagnostics,
    )
    return {
        "ok": result.returncode == 0,
        "device": device_summary(device),
        "exitCode": result.returncode,
        "reason": reason,
        "message": launch_result_message(result.stdout, result.stderr, launch_diagnostics),
        "launchJson": str(output),
        "command": shlex.join(command),
    }


def classify_launch_result(
    exit_code: int,
    stdout: str,
    stderr: str,
    diagnostics: str = "",
) -> str:
    if exit_code == 0:
        return ""
    text = f"{stdout}\n{stderr}\n{diagnostics}"
    if "device was not, or could not be, unlocked" in text or "BSErrorCodeDescription = Locked" in text:
        return "locked"
    if "unable to locate a device matching the requested device identifier" in text.casefold():
        return "device-unavailable"
    if "device disconnected immediately after connecting" in text:
        return "device-disconnected"
    if "application failed to launch" in text or "failed to launch" in text:
        return "launch-failed"
    return "device-command-failed"


def launch_result_message(stdout: str, stderr: str, diagnostics: str = "") -> str:
    lines = [
        line.strip()
        for line in (stderr + "\n" + stdout + "\n" + diagnostics).splitlines()
        if line.strip()
    ]
    for line in lines:
        if "Unable to launch" in line:
            return line
        if "The request was denied" in line:
            return line
        if "unable to locate a device matching the requested device identifier" in line.casefold():
            return line
        if "The device disconnected immediately after connecting" in line:
            return line
    for line in lines:
        stripped = line.strip()
        if "application failed to launch" in stripped or "failed to launch" in stripped:
            return stripped
    return ""


def launch_json_diagnostic_text(path: Path) -> str:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    lines: list[str] = []
    collect_json_strings(payload, lines)
    return "\n".join(lines)


def collect_json_strings(value: object, lines: list[str]) -> None:
    if isinstance(value, str):
        if value:
            lines.append(value)
        return
    if isinstance(value, list):
        for item in value:
            collect_json_strings(item, lines)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str) and key:
                lines.append(key)
            collect_json_strings(item, lines)


def diagnostics_bundle_id(args: argparse.Namespace) -> str:
    return args.diagnostics_bundle_id or args.default_bundle_id


def safe_path_component(value: str) -> str:
    cleaned = "".join(character if character.isalnum() or character in "-_" else "_" for character in value)
    return cleaned.strip("_") or "device"


def diagnostics_output_dir(args: argparse.Namespace, device: Device, kind: str) -> Path:
    if args.output_dir:
        base = Path(args.output_dir).expanduser()
        if kind == "diagnostics-connected":
            return base / safe_path_component(device.name or device.udid)
        return base
    return Path(args.artifact_dir) / f"{timestamp()}-{safe_path_component(device.name or device.udid)}-{kind}"


def run_devicectl_json_command(
    args: argparse.Namespace,
    output_path: Path,
    *devicectl_args: str,
    dry_run: bool = False,
) -> int:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "xcrun",
        "devicectl",
        "--timeout",
        str(args.timeout),
        "--json-output",
        str(output_path),
        *devicectl_args,
    ]
    result = run_maybe_dry(command, dry_run)
    return result.returncode


def devicectl_json_command(
    args: argparse.Namespace,
    output_path: Path,
    *devicectl_args: str,
    dry_run: bool = False,
) -> None:
    returncode = run_devicectl_json_command(args, output_path, *devicectl_args, dry_run=dry_run)
    if returncode != 0:
        raise SystemExit(returncode)


def write_diagnostics_manifest(output_dir: Path, device: Device, bundle_id: str, dry_run: bool) -> None:
    manifest = {
        "device": {
            "name": device.name,
            "udid": device.udid,
            "devicectlIdentifier": device.identifier,
            "model": device.model,
            "osVersion": device.os_version,
            "transport": device.transport,
        },
        "bundleId": bundle_id,
        "appDiagnosticsSource": "Library/Application Support/Diagnostics",
        "createdAt": timestamp(),
        "dryRun": dry_run,
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")


def diagnostics_file_relative_paths(files_payload: dict[str, object]) -> list[str]:
    result = files_payload.get("result")
    if not isinstance(result, dict):
        return []
    files = result.get("files")
    if not isinstance(files, list):
        return []

    paths: list[str] = []
    for entry in files:
        if not isinstance(entry, dict):
            continue
        resources = entry.get("resources")
        if isinstance(resources, dict):
            if resources.get("isDirectory") is True:
                continue
            if resources.get("isReadable") is False:
                continue
        relative_path = entry.get("relativePath") or entry.get("name")
        if not isinstance(relative_path, str):
            continue
        relative_path = relative_path.strip().lstrip("/")
        if not relative_path or relative_path.startswith("../") or "/../" in relative_path:
            continue
        paths.append(relative_path)
    return sorted(set(paths))


def read_diagnostics_file_paths(files_json_path: Path) -> list[str]:
    try:
        payload = json.loads(files_json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(payload, dict):
        return []
    return diagnostics_file_relative_paths(payload)


def sanitized_json_stem(relative_path: str) -> str:
    sanitized = "".join(character if character.isalnum() else "-" for character in relative_path)
    return sanitized.strip("-") or "diagnostic-file"


def copy_app_diagnostics(
    args: argparse.Namespace,
    *,
    output_dir: Path,
    app_diagnostics_destination: Path,
    device: Device,
    bundle_id: str,
) -> None:
    directory_copy_exit = run_devicectl_json_command(
        args,
        output_dir / "app-diagnostics-copy.json",
        "device",
        "copy",
        "from",
        "--device",
        device.devicectl_identifier,
        "--domain-type",
        "appDataContainer",
        "--domain-identifier",
        bundle_id,
        "--source",
        "Library/Application Support/Diagnostics",
        "--destination",
        str(app_diagnostics_destination),
        dry_run=args.dry_run,
    )
    if directory_copy_exit == 0:
        return
    if args.dry_run:
        raise SystemExit(directory_copy_exit)

    copied_any = False
    for relative_path in read_diagnostics_file_paths(output_dir / "app-diagnostics-files.json"):
        destination = app_diagnostics_destination / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        file_copy_exit = run_devicectl_json_command(
            args,
            output_dir / f"app-diagnostics-copy-{sanitized_json_stem(relative_path)}.json",
            "device",
            "copy",
            "from",
            "--device",
            device.devicectl_identifier,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            bundle_id,
            "--source",
            f"Library/Application Support/Diagnostics/{relative_path}",
            "--destination",
            str(destination),
            dry_run=False,
        )
        copied_any = copied_any or file_copy_exit == 0

    if not copied_any:
        raise SystemExit(directory_copy_exit)


def copy_crash_logs(
    args: argparse.Namespace,
    *,
    output_dir: Path,
    crash_logs_destination: Path,
    device: Device,
) -> None:
    if not args.dry_run:
        crash_logs_destination.mkdir(parents=True, exist_ok=True)
    returncode = run_devicectl_json_command(
        args,
        output_dir / "crash-logs-copy.json",
        "device",
        "copy",
        "from",
        "--device",
        device.devicectl_identifier,
        "--domain-type",
        "systemCrashLogs",
        "--source",
        ".",
        "--destination",
        str(crash_logs_destination),
        dry_run=args.dry_run,
    )
    if returncode == 0 or args.dry_run:
        return
    (output_dir / "crash-logs-copy-warning.txt").write_text(
        (
            "Crash-log copy exited nonzero, but devicectl may have copied partial logs. "
            f"Continuing diagnostics capture. exit={returncode}\n"
        ),
        encoding="utf-8",
    )


def write_log_tail(output_dir: Path, tail_bytes: int) -> None:
    if tail_bytes <= 0:
        return
    copied_logs = sorted(output_dir.rglob("beepbeep-diagnostics.log"))
    if not copied_logs:
        return
    source = copied_logs[0]
    data = source.read_bytes()
    tail = data[-tail_bytes:]
    destination = output_dir / "beepbeep-diagnostics-tail.log"
    prefix = b""
    if len(data) > len(tail):
        prefix = f"<truncated to last {tail_bytes} bytes from {source}>\n".encode()
    destination.write_bytes(prefix + tail)


def extract_diagnostics(args: argparse.Namespace, device: Device, *, connected_mode: bool = False) -> Path:
    bundle_id = diagnostics_bundle_id(args)
    output_dir = diagnostics_output_dir(args, device, "diagnostics-connected" if connected_mode else "diagnostics")
    app_diagnostics_destination = output_dir / "app-diagnostics"
    crash_logs_destination = output_dir / "crash-logs"
    sysdiagnose_destination = output_dir / "sysdiagnose"

    if not args.dry_run:
        output_dir.mkdir(parents=True, exist_ok=True)
        app_diagnostics_destination.mkdir(parents=True, exist_ok=True)
    write_diagnostics_manifest(output_dir, device, bundle_id, args.dry_run)

    devicectl_json_command(
        args,
        output_dir / "device-details.json",
        "device",
        "info",
        "details",
        "--device",
        device.devicectl_identifier,
        dry_run=args.dry_run,
    )
    devicectl_json_command(
        args,
        output_dir / "installed-app.json",
        "device",
        "info",
        "apps",
        "--device",
        device.devicectl_identifier,
        "--bundle-id",
        bundle_id,
        dry_run=args.dry_run,
    )
    devicectl_json_command(
        args,
        output_dir / "app-diagnostics-files.json",
        "device",
        "info",
        "files",
        "--device",
        device.devicectl_identifier,
        "--domain-type",
        "appDataContainer",
        "--domain-identifier",
        bundle_id,
        "--subdirectory",
        "Library/Application Support/Diagnostics",
        dry_run=args.dry_run,
    )
    copy_app_diagnostics(
        args,
        output_dir=output_dir,
        app_diagnostics_destination=app_diagnostics_destination,
        device=device,
        bundle_id=bundle_id,
    )

    if args.include_crash_logs:
        copy_crash_logs(
            args,
            output_dir=output_dir,
            crash_logs_destination=crash_logs_destination,
            device=device,
        )

    if args.include_sysdiagnose:
        gather_sysdiagnose(args, device, sysdiagnose_destination)

    if not args.dry_run:
        write_log_tail(output_dir, args.tail_bytes)
    print(f"device diagnostics: {output_dir}")
    return output_dir


def gather_sysdiagnose(args: argparse.Namespace, device: Device, output_dir: Path | None = None) -> Path:
    destination = output_dir or diagnostics_output_dir(args, device, "sysdiagnose")
    if not args.dry_run:
        destination.mkdir(parents=True, exist_ok=True)
    command = [
        "xcrun",
        "devicectl",
        "--timeout",
        str(args.timeout),
        "--json-output",
        str(destination / "sysdiagnose.json"),
        "device",
        "sysdiagnose",
        "--device",
        device.devicectl_identifier,
        "--destination",
        str(destination),
    ]
    if getattr(args, "gather_full_logs", False):
        command.append("--gather-full-logs")
    result = run_maybe_dry(command, args.dry_run)
    if result.returncode != 0:
        raise SystemExit(result.returncode)
    print(f"device sysdiagnose: {destination}")
    return destination


def result_bundle_path(args: argparse.Namespace, device: Device) -> Path:
    if args.result_bundle_path:
        return Path(args.result_bundle_path)
    safe_device = "".join(character if character.isalnum() or character in "-_" else "_" for character in device.name)
    return Path(args.artifact_dir) / f"{timestamp()}-{safe_device or device.udid}-device-tests.xcresult"


def total_test_count(path: Path) -> int:
    result = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(path),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stdout, end="")
        print(result.stderr, file=sys.stderr, end="")
        raise SystemExit(result.returncode)
    payload = json.loads(result.stdout)
    top_level_total = payload.get("totalTestCount")
    if top_level_total is not None:
        return int(top_level_total)
    return int(payload.get("devicesAndConfigurations", [{}])[0].get("totalTestCount", 0))


def run_xcodebuild_test(command: list[str], names: list[str]) -> tuple[int, list[str]]:
    print("+ " + shlex.join(command), file=sys.stderr)
    seen = {name.removesuffix("()"): False for name in names}
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        for name in seen:
            if f"Test {name}()" in line:
                seen[name] = True
    return process.wait(), [name for name, was_seen in seen.items() if not was_seen]


def run_tests(args: argparse.Namespace, device: Device) -> None:
    result_path = result_bundle_path(args, device)
    result_path.parent.mkdir(parents=True, exist_ok=True)
    if result_path.exists():
        if result_path.is_dir():
            shutil.rmtree(result_path)
        else:
            result_path.unlink()

    selectors: list[str] = []
    required_names: list[str] = []
    if args.name:
        selectors, required_names = discover_swift_testing_selectors(
            Path.cwd() / args.test_source_dir,
            args.test_target,
            args.name,
        )
    only_testing = selectors or [value for value in args.only_testing if value]
    if not only_testing and not args.name:
        only_testing = ["TurboTests"]
    skip_testing = [value for value in args.skip_testing if value]
    if not skip_testing and not args.name and not args.only_testing:
        skip_testing = ["TurboUITests"]

    command = [
        "xcodebuild",
        "-project",
        args.project,
        "-scheme",
        args.scheme,
        "-configuration",
        args.configuration,
        "-destination",
        xcode_destination(device),
        "-derivedDataPath",
        args.derived_data,
        "-resultBundlePath",
        str(result_path),
        *signing_update_flags(),
        *[f"-only-testing:{selector}" for selector in only_testing],
        *[f"-skip-testing:{selector}" for selector in skip_testing],
        "-parallel-testing-enabled",
        "NO",
        "-maximum-parallel-testing-workers",
        "1",
        "test",
    ]
    exit_code, missing = run_xcodebuild_test(command, required_names)
    print(f"xcodebuild result bundle: {result_path}", file=sys.stderr)
    if exit_code != 0:
        raise SystemExit(exit_code)
    if missing:
        print("Requested Swift tests did not execute: " + ", ".join(missing), file=sys.stderr)
        raise SystemExit(1)
    test_count = total_test_count(result_path)
    if test_count <= 0:
        raise SystemExit("Physical-device test run executed zero tests according to xcresult summary.")
    print(f"device-test: xcresult reported {test_count} tests executed", file=sys.stderr)


def command_list(args: argparse.Namespace) -> None:
    devices = connected_devices(args)
    if args.json:
        print(json.dumps([device.__dict__ for device in devices], indent=2, sort_keys=True))
    else:
        print_devices(devices)


def command_info(args: argparse.Namespace) -> None:
    device = resolve_device(args)
    command = [
        "xcrun",
        "devicectl",
        "--timeout",
        str(args.timeout),
        "device",
        "info",
        "details",
        "--device",
        device.devicectl_identifier,
    ]
    result = run(command)
    raise SystemExit(result.returncode)


def lock_state_for_device(args: argparse.Namespace, device: Device) -> dict[str, object]:
    try:
        payload = devicectl_json(
            args,
            "device",
            "info",
            "lockState",
            "--device",
            device.devicectl_identifier,
        )
    except subprocess.CalledProcessError as exc:
        return {
            "ok": False,
            "device": device_summary(device),
            "error": (exc.stderr or exc.output or str(exc)).strip(),
            "exitCode": exc.returncode,
        }
    result = payload.get("result", {})
    if not isinstance(result, dict):
        result = {}
    current_locked = first_present(result, ["locked", "isLocked", "deviceLocked"])
    return {
        "ok": True,
        "device": device_summary(device),
        "deviceIdentifier": result.get("deviceIdentifier"),
        "passcodeRequired": result.get("passcodeRequired"),
        "unlockedSinceBoot": result.get("unlockedSinceBoot"),
        "currentLocked": current_locked,
        "currentLockStateKnown": current_locked is not None,
        "rawResultKeys": sorted(str(key) for key in result.keys()),
    }


def first_present(payload: dict[str, object], keys: list[str]) -> object | None:
    for key in keys:
        if key in payload:
            return payload[key]
    return None


def device_summary(device: Device) -> dict[str, str]:
    return {
        "name": device.name,
        "udid": device.udid,
        "devicectlIdentifier": device.identifier,
        "model": device.model,
        "osVersion": device.os_version,
        "transport": device.transport,
        "state": device.state,
    }


def print_lock_states(lock_states: list[dict[str, object]]) -> None:
    if not lock_states:
        print("No available paired physical iOS devices found.")
        return
    headers = ["Name", "UDID", "State", "OK", "UnlockedSinceBoot", "CurrentLockKnown"]
    rows: list[list[str]] = []
    for item in lock_states:
        device = item.get("device", {})
        if not isinstance(device, dict):
            device = {}
        rows.append(
            [
                str(device.get("name") or ""),
                str(device.get("udid") or ""),
                str(device.get("state") or ""),
                str(item.get("ok") is True),
                str(item.get("unlockedSinceBoot") if item.get("ok") is True else ""),
                str(item.get("currentLockStateKnown") if item.get("ok") is True else ""),
            ]
        )
    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))
    print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(value.ljust(widths[index]) for index, value in enumerate(row)))


def command_lock_state(args: argparse.Namespace) -> None:
    device = resolve_device(args)
    lock_state = lock_state_for_device(args, device)
    if args.json:
        print(json.dumps(lock_state, indent=2, sort_keys=True))
    else:
        print_lock_states([lock_state])
    if lock_state.get("ok") is not True:
        raise SystemExit(1)


def command_lock_state_connected(args: argparse.Namespace) -> None:
    devices = connected_devices(args)
    if not devices:
        raise SystemExit("No available paired physical iOS devices found.")
    lock_states = [lock_state_for_device(args, device) for device in devices]
    if args.json:
        print(json.dumps(lock_states, indent=2, sort_keys=True))
    else:
        print_lock_states(lock_states)
    if any(item.get("ok") is not True for item in lock_states):
        raise SystemExit(1)


def command_build(args: argparse.Namespace) -> None:
    device = resolve_device(args)
    build_app(args, device)


def command_install(args: argparse.Namespace) -> None:
    device = resolve_device(args)
    app_path = Path(args.app_path).expanduser() if args.app_path else build_app(args, device)
    install_app(args, device, app_path)


def command_launch(args: argparse.Namespace) -> None:
    device = resolve_device(args)
    launch_app(args, device)


def command_launch_connected(args: argparse.Namespace) -> None:
    devices = connected_devices(args)
    if not devices:
        raise SystemExit("No available paired physical iOS devices found.")
    if args.json or args.output:
        launch_results = [launch_probe_for_device(args, device) for device in devices]
        payload = json.dumps(launch_results, indent=2, sort_keys=True) + "\n"
        if args.output:
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(payload, encoding="utf-8")
            print(f"device launch-connected JSON: {output}", file=sys.stderr)
        if args.json:
            print(payload, end="")
        if any(item.get("ok") is not True for item in launch_results):
            raise SystemExit(1)
        return
    failures: list[str] = []
    for device in devices:
        print(f"== {device.name} ({device.udid}) ==", file=sys.stderr)
        try:
            launch_app(args, device)
        except SystemExit as exc:
            failure = device_failure_summary(device, exc)
            failures.append(failure)
            print(failure, file=sys.stderr)
            if not args.continue_on_device_error:
                raise
    if failures:
        raise SystemExit("launch-connected failed for device(s): " + "; ".join(failures))


def command_run(args: argparse.Namespace) -> None:
    device = resolve_device(args)
    app_path = build_app(args, device)
    install_app(args, device, app_path)
    launch_app(args, device)


def command_run_connected(args: argparse.Namespace) -> None:
    devices = connected_devices(args)
    if not devices:
        raise SystemExit("No available paired physical iOS devices found.")
    failures: list[str] = []
    for device in devices:
        print(f"== {device.name} ({device.udid}) ==", file=sys.stderr)
        try:
            app_path = build_app(args, device)
            install_app(args, device, app_path)
            launch_app(args, device)
        except SystemExit as exc:
            failure = device_failure_summary(device, exc)
            failures.append(failure)
            print(failure, file=sys.stderr)
            if not args.continue_on_device_error:
                raise
    if failures:
        raise SystemExit("run-connected failed for device(s): " + "; ".join(failures))


def device_failure_summary(device: Device, exc: SystemExit) -> str:
    code = exc.code if exc.code is not None else 1
    return f"{device.name or device.udid or device.identifier} ({device.udid or device.identifier}) exit={code}"


def command_diagnostics(args: argparse.Namespace) -> None:
    device = resolve_device(args)
    extract_diagnostics(args, device)


def command_diagnostics_connected(args: argparse.Namespace) -> None:
    devices = connected_devices(args)
    if not devices:
        raise SystemExit("No available paired physical iOS devices found.")
    for device in devices:
        extract_diagnostics(args, device, connected_mode=True)


def command_sysdiagnose(args: argparse.Namespace) -> None:
    device = resolve_device(args)
    gather_sysdiagnose(args, device)


def command_test(args: argparse.Namespace) -> None:
    device = resolve_device(args)
    run_tests(args, device)


def main() -> int:
    args = parse_args()
    commands = {
        "list": command_list,
        "info": command_info,
        "lock-state": command_lock_state,
        "lock-state-connected": command_lock_state_connected,
        "build": command_build,
        "install": command_install,
        "launch": command_launch,
        "launch-connected": command_launch_connected,
        "run": command_run,
        "run-connected": command_run_connected,
        "diagnostics": command_diagnostics,
        "diagnostics-connected": command_diagnostics_connected,
        "sysdiagnose": command_sysdiagnose,
        "test": command_test,
    }
    try:
        commands[args.command](args)
    except subprocess.CalledProcessError as exc:
        print(exc.stdout or "", end="")
        print(exc.stderr or "", file=sys.stderr, end="")
        return exc.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
