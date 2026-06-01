#!/usr/bin/env python3

import argparse
import base64
import json
import os
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_private_key_pem() -> bytes:
    key_text = os.environ.get("TURBO_APNS_PRIVATE_KEY")
    if key_text:
        return key_text.encode("utf-8")

    key_path = os.environ.get("TURBO_APNS_PRIVATE_KEY_PATH")
    if key_path:
        return Path(key_path).read_bytes()

    raise SystemExit("Missing TURBO_APNS_PRIVATE_KEY or TURBO_APNS_PRIVATE_KEY_PATH")


def apns_credential_inputs(env: dict[str, str] | None = None) -> dict:
    values = os.environ if env is None else env
    missing: list[str] = []
    if not values.get("TURBO_APNS_TEAM_ID"):
        missing.append("TURBO_APNS_TEAM_ID")
    if not values.get("TURBO_APNS_KEY_ID"):
        missing.append("TURBO_APNS_KEY_ID")
    if not values.get("TURBO_APNS_PRIVATE_KEY") and not values.get("TURBO_APNS_PRIVATE_KEY_PATH"):
        missing.append("TURBO_APNS_PRIVATE_KEY or TURBO_APNS_PRIVATE_KEY_PATH")
    key_path = values.get("TURBO_APNS_PRIVATE_KEY_PATH")
    key_path_exists = None
    if key_path:
        key_path_exists = Path(key_path).exists()
        if not key_path_exists:
            missing.append("TURBO_APNS_PRIVATE_KEY_PATH exists")
    return {
        "ok": not missing,
        "missing": missing,
        "hasTeamId": bool(values.get("TURBO_APNS_TEAM_ID")),
        "hasKeyId": bool(values.get("TURBO_APNS_KEY_ID")),
        "hasInlinePrivateKey": bool(values.get("TURBO_APNS_PRIVATE_KEY")),
        "hasPrivateKeyPath": bool(key_path),
        "privateKeyPathExists": key_path_exists,
    }


def der_to_raw_ecdsa_signature(der: bytes, component_size: int = 32) -> bytes:
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("Unexpected DER signature format")

    index = 2
    if der[1] & 0x80:
        length_len = der[1] & 0x7F
        index = 2 + length_len

    if der[index] != 0x02:
        raise ValueError("Missing DER integer for r")
    r_len = der[index + 1]
    r = der[index + 2:index + 2 + r_len]
    index = index + 2 + r_len

    if der[index] != 0x02:
        raise ValueError("Missing DER integer for s")
    s_len = der[index + 1]
    s = der[index + 2:index + 2 + s_len]

    r = r.lstrip(b"\x00").rjust(component_size, b"\x00")
    s = s.lstrip(b"\x00").rjust(component_size, b"\x00")
    return r + s


def sign_es256(message: bytes, private_key_pem: bytes) -> bytes:
    with tempfile.TemporaryDirectory(prefix="turbo-apns-sign-") as tmpdir:
        key_path = Path(tmpdir) / "AuthKey.p8"
        payload_path = Path(tmpdir) / "payload.txt"
        sig_path = Path(tmpdir) / "sig.der"
        key_path.write_bytes(private_key_pem)
        payload_path.write_bytes(message)
        subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-sign",
                str(key_path),
                "-out",
                str(sig_path),
                str(payload_path),
            ],
            check=True,
            capture_output=True,
        )
        der = sig_path.read_bytes()
    return der_to_raw_ecdsa_signature(der)


def make_apns_jwt(team_id: str, key_id: str, private_key_pem: bytes) -> str:
    header = {"alg": "ES256", "kid": key_id}
    claims = {"iss": team_id, "iat": int(time.time())}
    signing_input = (
        f"{b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{b64url(json.dumps(claims, separators=(',', ':')).encode())}"
    ).encode("ascii")
    signature = sign_es256(signing_input, private_key_pem)
    return f"{signing_input.decode('ascii')}.{b64url(signature)}"


@dataclass
class APNSJWTProvider:
    team_id: str
    key_id: str
    private_key_pem: bytes
    refresh_interval_seconds: int = 30 * 60
    _token: str | None = None
    _issued_at: int = 0

    def current_token(self) -> str:
        now = int(time.time())
        if self._token is None or now - self._issued_at >= self.refresh_interval_seconds:
            self._token = make_apns_jwt(self.team_id, self.key_id, self.private_key_pem)
            self._issued_at = now
        return self._token

    def force_refresh(self) -> str:
        self._token = make_apns_jwt(self.team_id, self.key_id, self.private_key_pem)
        self._issued_at = int(time.time())
        return self._token


class BackendRequestError(RuntimeError):
    def __init__(self, *, message: str, status: int = 0, body: str = "") -> None:
        super().__init__(message)
        self.status = status
        self.body = body

    def payload(self, *, channel_id: str, handle: str) -> dict:
        result = {
            "ok": False,
            "stage": "backend-push-target",
            "error": str(self),
            "channelId": channel_id,
            "handle": handle,
        }
        if self.status:
            result["status"] = self.status
        if self.body:
            result["body"] = self.body
        return result


def backend_request(url: str, handle: str, insecure: bool) -> dict:
    command = [
        "curl",
        "-sS",
        "-H",
        f"x-turbo-user-handle: {handle}",
        "-H",
        f"Authorization: Bearer {handle}",
        "-H",
        "Accept: application/json",
    ]
    if insecure:
        command.append("-k")
    command.extend(["-w", "\n%{http_code}"])
    command.append(url)
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    raw = completed.stdout or ""
    body, _, status_text = raw.rpartition("\n")
    try:
        status = int(status_text.strip())
    except ValueError:
        status = 0
        body = raw.strip()
    if completed.returncode != 0:
        error_body = (body or completed.stderr or "").strip()
        raise BackendRequestError(
            message=f"backend push-target curl exited {completed.returncode}",
            status=status,
            body=error_body,
        )
    if status < 200 or status >= 300:
        raise BackendRequestError(
            message=f"backend push-target request failed with HTTP {status}",
            status=status,
            body=body.strip(),
        )
    payload = body.strip()
    if not payload:
        return {}
    try:
        return json.loads(payload)
    except json.JSONDecodeError as exc:
        raise BackendRequestError(
            message=f"backend push-target response was not JSON: {exc}",
            status=status,
            body=payload,
        ) from exc


def apns_host() -> str:
    use_sandbox = os.environ.get("TURBO_APNS_USE_SANDBOX", "1").lower() not in {"0", "false", "no"}
    return "api.sandbox.push.apple.com" if use_sandbox else "api.push.apple.com"


def send_apns(token: str, payload: dict, jwt_token: str, bundle_id: str) -> tuple[int, str]:
    url = f"https://{apns_host()}/3/device/{token}"
    command = [
        "curl",
        "-sS",
        "--http2",
        "-X",
        "POST",
        "-H",
        f"authorization: bearer {jwt_token}",
        "-H",
        "apns-push-type: pushtotalk",
        "-H",
        f"apns-topic: {bundle_id}.voip-ptt",
        "-H",
        "apns-priority: 10",
        "-H",
        "apns-expiration: 0",
        "-H",
        "content-type: application/json",
        "--data-binary",
        json.dumps(payload),
        "-w",
        "\n%{http_code}",
        url,
    ]
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
        raw = completed.stdout
    except subprocess.CalledProcessError as error:
        raw = error.stdout or error.stderr or ""
    body, _, status_text = raw.rpartition("\n")
    try:
        status = int(status_text.strip())
    except ValueError:
        status = 0
        body = raw.strip()
    return status, body.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Send a real PushToTalk APNs wake push using Turbo's canonical push-target route.")
    parser.add_argument("--base-url", default="https://staging.beepbeep.to", help="Turbo backend base URL")
    parser.add_argument("--handle", default="", help="Sender handle")
    parser.add_argument("--channel-id", default="", help="Backend channel id")
    parser.add_argument("--bundle-id", default="com.rounded.Turbo", help="App bundle identifier")
    parser.add_argument("--insecure", action="store_true", help="Disable TLS verification when talking to the Turbo backend")
    parser.add_argument("--print-only", action="store_true", help="Print the APNs request instead of sending it")
    parser.add_argument("--check-credentials", action="store_true", help="Check local APNs signing credential inputs and exit without contacting backend/APNs")
    args = parser.parse_args()

    if args.check_credentials:
        summary = apns_credential_inputs()
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0 if summary["ok"] else 1

    if not args.handle or not args.channel_id:
        raise SystemExit("--handle and --channel-id are required unless --check-credentials is used")

    push_target_url = f"{args.base_url.rstrip('/')}/v1/channels/{args.channel_id}/ptt-push-target"
    try:
        push_target = backend_request(push_target_url, args.handle, args.insecure)
    except BackendRequestError as exc:
        print(
            json.dumps(
                exc.payload(channel_id=args.channel_id, handle=args.handle),
                indent=2,
                sort_keys=True,
            )
        )
        return 1
    except Exception as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "stage": "backend-push-target",
                    "error": str(exc),
                    "channelId": args.channel_id,
                    "handle": args.handle,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 1

    try:
        payload = {
            "aps": {},
            "event": push_target["event"],
            "channelId": push_target["channelId"],
            "activeSpeaker": push_target["activeSpeaker"],
            "senderUserId": push_target["senderUserId"],
            "senderDeviceId": push_target["senderDeviceId"],
        }
    except KeyError as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "stage": "backend-push-target",
                    "error": f"push target response missing key: {exc}",
                    "channelId": args.channel_id,
                    "handle": args.handle,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 1

    if args.print_only:
        print(json.dumps({"ok": True, "token": push_target["token"], "payload": payload}, indent=2))
        return 0

    team_id = os.environ.get("TURBO_APNS_TEAM_ID")
    key_id = os.environ.get("TURBO_APNS_KEY_ID")
    if not team_id or not key_id:
        raise SystemExit("Missing TURBO_APNS_TEAM_ID or TURBO_APNS_KEY_ID")

    jwt_token = make_apns_jwt(team_id, key_id, load_private_key_pem())
    status, body = send_apns(push_target["token"], payload, jwt_token, args.bundle_id)
    print(json.dumps({"ok": 200 <= status < 300, "status": status, "body": body or "", "payload": payload}, indent=2))
    return 0 if 200 <= status < 300 else 1


if __name__ == "__main__":
    raise SystemExit(main())
