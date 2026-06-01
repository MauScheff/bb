#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
import os
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import send_ptt_apns


class SendPTTAPNSTests(unittest.TestCase):
    def test_apns_credential_inputs_reports_missing_values(self) -> None:
        summary = send_ptt_apns.apns_credential_inputs({})

        self.assertFalse(summary["ok"])
        self.assertIn("TURBO_APNS_TEAM_ID", summary["missing"])
        self.assertIn("TURBO_APNS_KEY_ID", summary["missing"])
        self.assertIn("TURBO_APNS_PRIVATE_KEY or TURBO_APNS_PRIVATE_KEY_PATH", summary["missing"])

    def test_apns_credential_inputs_accepts_existing_key_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            key_path = Path(temp_dir) / "AuthKey.p8"
            key_path.write_text("private-key", encoding="utf-8")

            summary = send_ptt_apns.apns_credential_inputs(
                {
                    "TURBO_APNS_TEAM_ID": "TEAMID",
                    "TURBO_APNS_KEY_ID": "KEYID",
                    "TURBO_APNS_PRIVATE_KEY_PATH": str(key_path),
                }
            )

        self.assertTrue(summary["ok"])
        self.assertTrue(summary["hasPrivateKeyPath"])
        self.assertTrue(summary["privateKeyPathExists"])

    def test_check_credentials_cli_does_not_require_wake_arguments(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with mock.patch.object(sys, "argv", ["send_ptt_apns.py", "--check-credentials"]):
                exit_code = send_ptt_apns.main()

        self.assertEqual(1, exit_code)

    def test_send_cli_requires_wake_arguments_when_not_checking_credentials(self) -> None:
        with mock.patch.object(sys, "argv", ["send_ptt_apns.py"]):
            with self.assertRaises(SystemExit):
                send_ptt_apns.main()

    def test_backend_push_target_failure_returns_json_error(self) -> None:
        with mock.patch.object(sys, "argv", ["send_ptt_apns.py", "--handle", "@sender", "--channel-id", "missing"]):
            with mock.patch.object(send_ptt_apns, "backend_request", side_effect=RuntimeError("not found")):
                exit_code = send_ptt_apns.main()

        self.assertEqual(1, exit_code)

    def test_backend_request_raises_structured_http_failure_without_raw_curl_command(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["curl"],
            returncode=0,
            stdout='{"error":"missing push target"}\n404',
            stderr="",
        )
        with mock.patch.object(send_ptt_apns.subprocess, "run", return_value=completed):
            with self.assertRaises(send_ptt_apns.BackendRequestError) as context:
                send_ptt_apns.backend_request("https://backend/v1/channels/missing/ptt-push-target", "@sender", False)

        self.assertEqual(404, context.exception.status)
        self.assertIn("missing push target", context.exception.body)
        payload = context.exception.payload(channel_id="missing", handle="@sender")
        self.assertEqual("backend-push-target", payload["stage"])
        self.assertEqual(404, payload["status"])
        self.assertNotIn("curl", payload["error"])

    def test_backend_request_raises_structured_json_parse_failure(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["curl"],
            returncode=0,
            stdout="not json\n200",
            stderr="",
        )
        with mock.patch.object(send_ptt_apns.subprocess, "run", return_value=completed):
            with self.assertRaises(send_ptt_apns.BackendRequestError) as context:
                send_ptt_apns.backend_request("https://backend/v1/channels/channel/ptt-push-target", "@sender", False)

        self.assertEqual(200, context.exception.status)
        self.assertIn("not JSON", str(context.exception))
        self.assertEqual("not json", context.exception.body)

    def test_print_only_success_includes_ok_true(self) -> None:
        push_target = {
            "token": "device-token",
            "event": "transmit-start",
            "channelId": "channel",
            "activeSpeaker": "@sender",
            "senderUserId": "sender-user",
            "senderDeviceId": "sender-device",
        }
        with mock.patch.object(sys, "argv", ["send_ptt_apns.py", "--handle", "@sender", "--channel-id", "channel", "--print-only"]):
            with mock.patch.object(send_ptt_apns, "backend_request", return_value=push_target):
                exit_code = send_ptt_apns.main()

        self.assertEqual(0, exit_code)


if __name__ == "__main__":
    unittest.main()
