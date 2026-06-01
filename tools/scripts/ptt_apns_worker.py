#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
import time

from send_ptt_apns import APNSJWTProvider, load_private_key_pem, send_apns


def request_json(
    url: str,
    worker_secret: str,
    method: str = "GET",
    body: dict | None = None,
    insecure: bool = False,
) -> tuple[int, dict]:
    command = [
        "curl",
        "-sS",
        "-X",
        method,
        "-H",
        f"x-turbo-worker-secret: {worker_secret}",
        "-H",
        "Accept: application/json",
        "-w",
        "\n%{http_code}",
    ]
    if insecure:
        command.append("-k")
    if body is not None:
        command.extend(["-H", "Content-Type: application/json", "--data-binary", json.dumps(body)])
    command.append(url)
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
        raw = completed.stdout
    except subprocess.CalledProcessError as error:
        raw = error.stdout or error.stderr or ""
    payload_text, _, status_text = raw.rpartition("\n")
    try:
        payload = json.loads(payload_text) if payload_text.strip() else {}
    except json.JSONDecodeError:
        payload = {"error": payload_text.strip()}
    try:
        status = int(status_text.strip())
    except ValueError:
        status = 0
    return status, payload


def fetch_jobs(base_url: str, worker_secret: str, insecure: bool) -> list[dict]:
    status, payload = request_json(
        f"{base_url.rstrip('/')}/v1/internal/wake-jobs",
        worker_secret,
        insecure=insecure,
    )
    if status < 200 or status >= 300:
        print(f"[worker] wake-job fetch failed status={status} payload={payload}", file=sys.stderr, flush=True)
        return []
    jobs = payload.get("jobs", [])
    return jobs if isinstance(jobs, list) else []


def ack_job(
    base_url: str,
    worker_secret: str,
    job: dict,
    *,
    result: str,
    status_code: int,
    response_body: str | None,
    insecure: bool,
) -> None:
    status, payload = request_json(
        f"{base_url.rstrip('/')}/v1/internal/wake-jobs/result",
        worker_secret,
        method="POST",
        body={
            "channelId": job["channelId"],
            "senderUserId": job["senderUserId"],
            "senderDeviceId": job["senderDeviceId"],
            "senderHandle": job["senderHandle"],
            "targetUserId": job["targetUserId"],
            "targetDeviceId": job["targetDeviceId"],
            "startedAt": job["startedAt"],
            "result": result,
            "statusCode": str(status_code),
            "responseBody": response_body,
        },
        insecure=insecure,
    )
    if 200 <= status < 300:
        return
    print(
        f"[worker] wake-job ack failed status={status} channel={job.get('channelId')} payload={payload}",
        file=sys.stderr,
        flush=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Drain backend-owned Turbo wake jobs and send APNs PushToTalk pushes.")
    parser.add_argument("--base-url", default="https://staging.beepbeep.to")
    parser.add_argument("--bundle-id", default="com.rounded.Turbo")
    parser.add_argument("--interval", type=float, default=0.75)
    parser.add_argument("--worker-secret", default=os.environ.get("TURBO_APNS_WORKER_SECRET", ""))
    parser.add_argument("--insecure", action="store_true")
    args = parser.parse_args()

    if not args.worker_secret:
        raise SystemExit("Missing --worker-secret or TURBO_APNS_WORKER_SECRET")

    team_id = os.environ.get("TURBO_APNS_TEAM_ID")
    key_id = os.environ.get("TURBO_APNS_KEY_ID")
    if not team_id or not key_id:
        raise SystemExit("Missing TURBO_APNS_TEAM_ID or TURBO_APNS_KEY_ID")

    jwt_provider = APNSJWTProvider(team_id, key_id, load_private_key_pem())
    print(f"[worker] polling {args.base_url.rstrip('/')}/v1/internal/wake-jobs", flush=True)

    while True:
        jobs = fetch_jobs(args.base_url, args.worker_secret, args.insecure)
        for job in jobs:
            try:
                apns_payload = {
                    "aps": {},
                    "event": job["event"],
                    "channelId": job["channelId"],
                    "activeSpeaker": job["activeSpeaker"],
                    "senderUserId": job["senderUserId"],
                    "senderDeviceId": job["senderDeviceId"],
                }
                status_code, body = send_apns(
                    job["token"],
                    apns_payload,
                    jwt_provider.current_token(),
                    args.bundle_id,
                )
                if status_code == 403 and body == '{"reason":"ExpiredProviderToken"}':
                    status_code, body = send_apns(
                        job["token"],
                        apns_payload,
                        jwt_provider.force_refresh(),
                        args.bundle_id,
                    )
            except Exception as error:
                print(
                    f"[worker] push send crashed channel={job.get('channelId')} target={job.get('targetDeviceId')} error={error}",
                    file=sys.stderr,
                    flush=True,
                )
                ack_job(
                    args.base_url,
                    args.worker_secret,
                    job,
                    result="send-crashed",
                    status_code=0,
                    response_body=str(error),
                    insecure=args.insecure,
                )
                continue

            if 200 <= status_code < 300:
                print(
                    f"[worker] sent wake push channel={job.get('channelId')} target={job.get('targetDeviceId')} startedAt={job.get('startedAt')} status={status_code}",
                    flush=True,
                )
                ack_job(
                    args.base_url,
                    args.worker_secret,
                    job,
                    result="sent",
                    status_code=status_code,
                    response_body=body or None,
                    insecure=args.insecure,
                )
            else:
                print(
                    f"[worker] push send failed channel={job.get('channelId')} target={job.get('targetDeviceId')} status={status_code} body={body}",
                    file=sys.stderr,
                    flush=True,
                )
                ack_job(
                    args.base_url,
                    args.worker_secret,
                    job,
                    result="failed",
                    status_code=status_code,
                    response_body=body or None,
                    insecure=args.insecure,
                )
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
