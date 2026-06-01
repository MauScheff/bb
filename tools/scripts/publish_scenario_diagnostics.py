#!/usr/bin/env python3

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Publish simulator scenario diagnostics artifacts to the backend."
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--artifacts-dir",
        help="Directory containing scenario artifact JSON files.",
    )
    source.add_argument(
        "--log-file",
        help="xcodebuild log file containing SCENARIO_DIAGNOSTICS_ARTIFACT lines.",
    )
    parser.add_argument(
        "--base-url",
        default="",
        help="Optional backend base URL override. Defaults to each artifact's baseURL.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Disable TLS certificate verification.",
    )
    return parser.parse_args()


def iter_artifacts(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*.json") if path.is_file())


def iter_artifacts_from_log(log_file: Path) -> list[tuple[str, dict[str, object]]]:
    artifacts: list[tuple[str, dict[str, object]]] = []
    for line in log_file.read_text(errors="replace").splitlines():
        prefix = "SCENARIO_DIAGNOSTICS_ARTIFACT "
        if not line.startswith(prefix):
            continue
        payload = json.loads(line[len(prefix):])
        handle = str(payload["handle"]).replace("@", "")
        scenario_name = str(payload.get("scenarioName", "scenario"))
        artifacts.append((f"{scenario_name}-{handle}.json", payload))
    return artifacts


def make_request(base_url: str, artifact: dict[str, object]) -> urllib.request.Request:
    payload = {
        "deviceId": artifact["deviceId"],
        "appVersion": artifact["appVersion"],
        "backendBaseURL": artifact["baseURL"],
        "selectedHandle": artifact.get("selectedHandle"),
        "snapshot": artifact["snapshot"],
        "transcript": artifact["transcript"],
    }
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/v1/dev/diagnostics",
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-turbo-user-handle": str(artifact["handle"]),
            "Authorization": f"Bearer {artifact['handle']}",
        },
    )
    return request


def make_latest_request(base_url: str, artifact: dict[str, object]) -> urllib.request.Request:
    device_id = str(artifact["deviceId"])
    return urllib.request.Request(
        f"{base_url.rstrip('/')}/v1/dev/diagnostics/latest/{device_id}/",
        method="GET",
        headers={
            "x-turbo-user-handle": str(artifact["handle"]),
            "Authorization": f"Bearer {artifact['handle']}",
        },
    )


def require_latest_report(payload: dict[str, object], artifact: dict[str, object]) -> dict[str, object]:
    status = payload.get("status")
    report = payload.get("report")
    if status != "ok" or not isinstance(report, dict):
        raise RuntimeError(f"latest diagnostics returned unexpected payload: {payload}")
    if report.get("deviceId") != artifact["deviceId"]:
        raise RuntimeError(
            f"latest diagnostics mismatched deviceId: expected {artifact['deviceId']} got {report.get('deviceId')}"
        )
    if report.get("appVersion") != artifact["appVersion"]:
        raise RuntimeError(
            f"latest diagnostics mismatched appVersion: expected {artifact['appVersion']} got {report.get('appVersion')}"
        )
    return report


def fetch_latest_report(
    request: urllib.request.Request,
    *,
    context: ssl.SSLContext | None,
    artifact_name: str,
    expected_device_id: object,
    expected_app_version: object,
    max_attempts: int = 10,
) -> dict[str, object]:
    last_payload: dict[str, object] | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            with urllib.request.urlopen(request, context=context) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{artifact_name}: latest verification failed: {exc.code} {body}") from exc

        last_payload = payload
        report = payload.get("report")
        if (
            payload.get("status") == "ok"
            and isinstance(report, dict)
            and report.get("deviceId") == expected_device_id
            and report.get("appVersion") == expected_app_version
        ):
            return report

        if attempt < max_attempts:
            import time

            time.sleep(0.3 * attempt)
            continue

    assert last_payload is not None
    return require_latest_report(last_payload, {"deviceId": expected_device_id, "appVersion": expected_app_version})


def main() -> int:
    args = parse_args()
    context = ssl._create_unverified_context() if args.insecure else None
    if args.log_file:
        log_file = Path(args.log_file)
        if not log_file.exists():
            raise RuntimeError(f"log file not found: {log_file}")
        artifacts = iter_artifacts_from_log(log_file)
        if not artifacts:
            raise RuntimeError(f"no scenario diagnostics artifacts found in {log_file}")
    else:
        artifacts_dir = Path(args.artifacts_dir)
        if not artifacts_dir.exists():
            raise RuntimeError(f"artifacts directory not found: {artifacts_dir}")
        paths = iter_artifacts(artifacts_dir)
        if not paths:
            raise RuntimeError(f"no scenario diagnostics artifacts found in {artifacts_dir}")
        artifacts = [(path.name, json.loads(path.read_text())) for path in paths]

    for artifact_name, artifact in artifacts:
        base_url = args.base_url or str(artifact["baseURL"])
        request = make_request(base_url, artifact)
        try:
            with urllib.request.urlopen(request, context=context) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{artifact_name}: upload failed: {exc.code} {body}") from exc

        report = payload.get("report", {})
        latest_request = make_latest_request(base_url, artifact)
        latest_report = fetch_latest_report(
            latest_request,
            context=context,
            artifact_name=artifact_name,
            expected_device_id=artifact["deviceId"],
            expected_app_version=artifact["appVersion"],
        )
        print(
            f"published {artifact_name} handle={artifact['handle']} "
            f"deviceId={report.get('deviceId', artifact['deviceId'])} "
            f"uploadedAt={latest_report.get('uploadedAt', report.get('uploadedAt', 'unknown'))}"
        )

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
