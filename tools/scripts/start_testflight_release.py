#!/usr/bin/env python3
"""Start Turbo's Xcode Cloud TestFlight release workflow.

This script intentionally releases only clean, pushed git commits. Xcode Cloud
builds from the connected repository, not from the local working tree.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_WORKFLOW_ID = "9195fc7c-1e0c-4a16-a3f0-daf74ecdd554"
API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_WHAT_TO_TEST = (
    "Try adding a contact, sending and receiving Beeps, connecting in "
    "the foreground and background, and talking for a while. If you need "
    "someone to test with, add @mau by username and try speaking with me. If "
    "something breaks, shake your phone to send a report so we can fix it."
)


class ReleaseError(Exception):
    pass


@dataclass(frozen=True)
class Credentials:
    key_id: str
    issuer_id: str
    private_key_path: Path


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def run(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(
            cmd,
            text=True,
            stderr=subprocess.STDOUT,
            timeout=60,
        ).strip()
    except subprocess.TimeoutExpired as error:
        raise ReleaseError(f"{' '.join(cmd)} timed out.") from error
    except subprocess.CalledProcessError as error:
        raise ReleaseError(f"{' '.join(cmd)} failed:\n{error.output.strip()}") from error


def require_clean_pushed_git() -> tuple[str, str]:
    branch = run(["git", "branch", "--show-current"])
    if not branch:
        raise ReleaseError("Not on a named git branch.")

    dirty = run(["git", "status", "--porcelain"])
    if dirty:
        raise ReleaseError(
            "Working tree is not clean. Commit or stash changes before releasing:\n"
            f"{dirty}"
        )

    upstream = run(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
    run(["git", "fetch", "--quiet"])
    head = run(["git", "rev-parse", "HEAD"])
    upstream_head = run(["git", "rev-parse", upstream])
    if head != upstream_head:
        raise ReleaseError(
            f"HEAD {head} is not the same as upstream {upstream} {upstream_head}. "
            "Push or pull before releasing."
        )
    return branch, head


def read_credentials() -> Credentials:
    missing = [
        name
        for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH")
        if not os.environ.get(name)
    ]
    if missing:
        raise ReleaseError(
            "Missing App Store Connect API environment variables: "
            + ", ".join(missing)
        )

    key_path = Path(os.environ["ASC_PRIVATE_KEY_PATH"]).expanduser()
    if not key_path.exists():
        raise ReleaseError(f"ASC_PRIVATE_KEY_PATH does not exist: {key_path}")
    return Credentials(
        key_id=os.environ["ASC_KEY_ID"],
        issuer_id=os.environ["ASC_ISSUER_ID"],
        private_key_path=key_path,
    )


def der_to_raw_ecdsa_signature(der: bytes) -> bytes:
    if len(der) < 8 or der[0] != 0x30:
        raise ReleaseError("OpenSSL returned an unexpected ECDSA signature.")
    index = 2
    if der[1] & 0x80:
        length_bytes = der[1] & 0x7F
        index = 2 + length_bytes
    if der[index] != 0x02:
        raise ReleaseError("Invalid ECDSA signature: missing r integer.")
    r_len = der[index + 1]
    r = der[index + 2 : index + 2 + r_len]
    index = index + 2 + r_len
    if der[index] != 0x02:
        raise ReleaseError("Invalid ECDSA signature: missing s integer.")
    s_len = der[index + 1]
    s = der[index + 2 : index + 2 + s_len]
    return r[-32:].rjust(32, b"\0") + s[-32:].rjust(32, b"\0")


def make_token(credentials: Credentials) -> str:
    now = int(time.time())
    header = {"alg": "ES256", "kid": credentials.key_id, "typ": "JWT"}
    payload = {
        "iss": credentials.issuer_id,
        "iat": now,
        "exp": now + 20 * 60,
        "aud": "appstoreconnect-v1",
    }
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    )
    signature_der = subprocess.check_output(
        [
            "openssl",
            "dgst",
            "-sha256",
            "-sign",
            str(credentials.private_key_path),
        ],
        input=signing_input.encode("ascii"),
    )
    signature = der_to_raw_ecdsa_signature(signature_der)
    return signing_input + "." + b64url(signature)


class AppStoreConnect:
    def __init__(self, token: str) -> None:
        self.token = token
        self.context = ssl.create_default_context()
        try:
            import certifi  # type: ignore

            self.context = ssl.create_default_context(cafile=certifi.where())
        except ImportError:
            pass

    def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            API_BASE + path,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=30,
                context=self.context,
            ) as response:
                text = response.read().decode("utf-8")
                if not text:
                    return {}
                return json.loads(text)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise ReleaseError(
                f"App Store Connect API {method} {path} failed "
                f"with HTTP {error.code}:\n{detail}"
            ) from error
        except urllib.error.URLError as error:
            raise ReleaseError(
                f"App Store Connect API {method} {path} failed: {error.reason}"
            ) from error


def start_build(api: AppStoreConnect, workflow_id: str) -> str:
    response = api.request(
        "POST",
        "/ciBuildRuns",
        {
            "data": {
                "type": "ciBuildRuns",
                "attributes": {},
                "relationships": {
                    "workflow": {
                        "data": {"type": "ciWorkflows", "id": workflow_id}
                    }
                },
            }
        },
    )
    return response["data"]["id"]


def poll_build_run(api: AppStoreConnect, build_run_id: str, timeout_seconds: int) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        response = api.request("GET", f"/ciBuildRuns/{build_run_id}")
        attrs = response["data"]["attributes"]
        progress = attrs.get("executionProgress")
        completion = attrs.get("completionStatus")
        print(
            f"Xcode Cloud build run: progress={progress} completion={completion}",
            flush=True,
        )
        if completion == "SUCCEEDED":
            return
        if completion and completion != "SUCCEEDED":
            raise ReleaseError(f"Xcode Cloud build did not succeed: {completion}")
        time.sleep(60)
    raise ReleaseError("Timed out waiting for Xcode Cloud build run to finish.")


def build_ids_for_run(api: AppStoreConnect, build_run_id: str) -> list[str]:
    response = api.request("GET", f"/ciBuildRuns/{build_run_id}/builds")
    return [item["id"] for item in response.get("data", [])]


def poll_processed_build(api: AppStoreConnect, build_id: str, timeout_seconds: int) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        response = api.request("GET", f"/builds/{build_id}")
        attrs = response["data"]["attributes"]
        processing = attrs.get("processingState")
        version = attrs.get("version")
        number = attrs.get("uploadedDate") or attrs.get("buildNumber") or build_id
        print(
            f"App Store Connect build: version={version} id={build_id} state={processing}",
            flush=True,
        )
        if processing in (None, "VALID"):
            print(f"Build is processed: {number}", flush=True)
            return
        if processing in ("FAILED", "INVALID"):
            raise ReleaseError(f"Build processing failed: {processing}")
        time.sleep(60)
    raise ReleaseError("Timed out waiting for App Store Connect build processing.")


def find_beta_group_id(api: AppStoreConnect, app_id: str, group_name: str) -> str:
    params = urllib.parse.urlencode({"filter[app]": app_id, "limit": "200"})
    response = api.request("GET", f"/betaGroups?{params}")
    matching_groups = []
    for group in response.get("data", []):
        if group.get("attributes", {}).get("name") == group_name:
            matching_groups.append(group)
    if not matching_groups:
        raise ReleaseError(f"No TestFlight beta group named {group_name!r} found for app {app_id}.")

    external_groups = [
        group
        for group in matching_groups
        if not group.get("attributes", {}).get("isInternalGroup", False)
    ]
    if len(external_groups) == 1:
        return external_groups[0]["id"]
    if len(matching_groups) == 1:
        return matching_groups[0]["id"]

    details = ", ".join(
        f"{group['id']} internal={group.get('attributes', {}).get('isInternalGroup')}"
        for group in matching_groups
    )
    raise ReleaseError(
        f"Multiple TestFlight beta groups named {group_name!r} matched: {details}. "
        "Set TESTFLIGHT_BETA_GROUP_ID to choose one explicitly."
    )


def add_build_to_beta_group(api: AppStoreConnect, build_id: str, beta_group_id: str) -> None:
    api.request(
        "POST",
        f"/builds/{build_id}/relationships/betaGroups",
        {"data": [{"type": "betaGroups", "id": beta_group_id}]},
    )


def set_what_to_test(
    api: AppStoreConnect,
    build_id: str,
    locale: str,
    what_to_test: str,
) -> None:
    response = api.request("GET", f"/builds/{build_id}/betaBuildLocalizations")
    existing = None
    for localization in response.get("data", []):
        if localization.get("attributes", {}).get("locale") == locale:
            existing = localization
            break

    if existing:
        api.request(
            "PATCH",
            f"/betaBuildLocalizations/{existing['id']}",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": existing["id"],
                    "attributes": {"whatsNew": what_to_test},
                }
            },
        )
    else:
        api.request(
            "POST",
            "/betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {
                        "locale": locale,
                        "whatsNew": what_to_test,
                    },
                    "relationships": {
                        "build": {
                            "data": {
                                "type": "builds",
                                "id": build_id,
                            }
                        }
                    },
                }
            },
        )


def submit_for_beta_review(api: AppStoreConnect, build_id: str) -> str:
    existing = api.request("GET", f"/builds/{build_id}/betaAppReviewSubmission")
    if existing.get("data"):
        submission = existing["data"]
        return submission["id"]

    response = api.request(
        "POST",
        "/betaAppReviewSubmissions",
        {
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {
                        "data": {
                            "type": "builds",
                            "id": build_id,
                        }
                    }
                },
            }
        },
    )
    return response["data"]["id"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workflow-id",
        default=os.environ.get("XCODE_CLOUD_WORKFLOW_ID", DEFAULT_WORKFLOW_ID),
        help="Xcode Cloud workflow ID to start.",
    )
    parser.add_argument(
        "--app-id",
        default=os.environ.get("ASC_APP_ID"),
        help="App Store Connect app ID, required when resolving a beta group by name.",
    )
    parser.add_argument(
        "--beta-group-id",
        default=os.environ.get("TESTFLIGHT_BETA_GROUP_ID"),
        help="TestFlight beta group ID to add the processed build to.",
    )
    parser.add_argument(
        "--beta-group-name",
        default=os.environ.get("TESTFLIGHT_BETA_GROUP_NAME"),
        help="TestFlight beta group name to resolve and add the processed build to.",
    )
    parser.add_argument("--build-timeout-minutes", type=int, default=90)
    parser.add_argument("--processing-timeout-minutes", type=int, default=60)
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="Start the Xcode Cloud build and return immediately.",
    )
    parser.add_argument(
        "--skip-git-checks",
        action="store_true",
        help="Bypass clean/pushed git checks. Intended only for API smoke testing.",
    )
    parser.add_argument(
        "--assign-build-id",
        help="Skip Xcode Cloud and assign an existing processed App Store Connect build ID.",
    )
    parser.add_argument(
        "--what-to-test",
        default=os.environ.get("TESTFLIGHT_WHAT_TO_TEST", DEFAULT_WHAT_TO_TEST),
        help="Text to put in TestFlight's What to Test field.",
    )
    parser.add_argument(
        "--locale",
        default=os.environ.get("TESTFLIGHT_LOCALE", "en-US"),
        help="Beta build localization locale.",
    )
    parser.add_argument(
        "--skip-beta-review-submit",
        action="store_true",
        help="Add the build to the group but do not submit it for external beta review.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if not args.skip_git_checks:
            branch, commit = require_clean_pushed_git()
            print(f"Releasing pushed commit {commit} from {branch}.", flush=True)

        credentials = read_credentials()
        api = AppStoreConnect(make_token(credentials))

        if args.assign_build_id:
            build_id = args.assign_build_id
            print(f"Assigning existing App Store Connect build: {build_id}", flush=True)
        else:
            build_run_id = start_build(api, args.workflow_id)
            print(f"Started Xcode Cloud build run: {build_run_id}", flush=True)

            if args.no_wait:
                return 0

            poll_build_run(api, build_run_id, args.build_timeout_minutes * 60)
            build_ids = build_ids_for_run(api, build_run_id)
            if not build_ids:
                raise ReleaseError("Xcode Cloud run succeeded but no App Store build was linked.")
            build_id = build_ids[-1]
            poll_processed_build(api, build_id, args.processing_timeout_minutes * 60)

        beta_group_id = args.beta_group_id
        if beta_group_id is None and args.beta_group_name:
            if not args.app_id:
                raise ReleaseError("--app-id or ASC_APP_ID is required with --beta-group-name.")
            beta_group_id = find_beta_group_id(api, args.app_id, args.beta_group_name)

        if beta_group_id:
            set_what_to_test(api, build_id, args.locale, args.what_to_test)
            print(f"Set TestFlight What to Test text for {args.locale}.", flush=True)
            add_build_to_beta_group(api, build_id, beta_group_id)
            print(
                f"Added build {build_id} to TestFlight beta group {beta_group_id}.",
                flush=True,
            )
            if not args.skip_beta_review_submit:
                submission_id = submit_for_beta_review(api, build_id)
                print(
                    f"Submitted build {build_id} for external beta review: {submission_id}.",
                    flush=True,
                )
        else:
            print(
                "No TestFlight beta group configured; build was not assigned to a group.",
                flush=True,
            )
        return 0
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
