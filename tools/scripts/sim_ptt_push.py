#!/usr/bin/env python3

import argparse
import json
import subprocess
import tempfile
from pathlib import Path


def build_payload(args: argparse.Namespace) -> dict:
    return {
        "Simulator Target Bundle": args.bundle_id,
        "aps": {},
        "event": args.event,
        "channelId": args.channel_id,
        "activeSpeaker": args.active_speaker,
        "senderUserId": args.sender_user_id,
        "senderDeviceId": args.sender_device_id,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Send a simulated PushToTalk APNs payload to an iOS simulator.")
    parser.add_argument("--device", default="booted", help="Simulator device id or 'booted'")
    parser.add_argument("--bundle-id", default="com.rounded.Turbo", help="App bundle identifier")
    parser.add_argument("--event", choices=["transmit-start", "leave-channel"], default="transmit-start")
    parser.add_argument("--channel-id", required=True, help="Backend channel id")
    parser.add_argument("--active-speaker", default="@blake", help="Speaker handle shown to PushToTalk")
    parser.add_argument("--sender-user-id", default="user-blake", help="Sender backend user id")
    parser.add_argument("--sender-device-id", default="device-blake", help="Sender backend device id")
    parser.add_argument("--print-only", action="store_true", help="Print the generated payload instead of sending it")
    args = parser.parse_args()

    payload = build_payload(args)

    if args.print_only:
        print(json.dumps(payload, indent=2))
        return 0

    with tempfile.TemporaryDirectory(prefix="turbo-ptt-push-") as tmpdir:
        payload_path = Path(tmpdir) / "ptt.apns"
        payload_path.write_text(json.dumps(payload), encoding="utf-8")
        subprocess.run(
            [
                "xcrun",
                "simctl",
                "push",
                args.device,
                args.bundle_id,
                str(payload_path),
            ],
            check=True,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
