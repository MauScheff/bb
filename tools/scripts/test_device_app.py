#!/usr/bin/env python3

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import device_app


class DeviceAppTests(unittest.TestCase):
    def test_run_connected_parser_accepts_continue_on_device_error_before_launch_args(self) -> None:
        args = device_app.parse_args_for_test(
            [
                "run-connected",
                "--terminate-existing",
                "--continue-on-device-error",
                "--env",
                "TURBO_DEBUG_MEDIA_RELAY_ENABLED=0",
            ]
        )

        self.assertTrue(args.continue_on_device_error)
        self.assertTrue(args.terminate_existing)
        self.assertEqual(["TURBO_DEBUG_MEDIA_RELAY_ENABLED=0"], args.env)

    def test_launch_connected_parser_accepts_continue_on_device_error_before_launch_args(self) -> None:
        args = device_app.parse_args_for_test(
            [
                "launch-connected",
                "--terminate-existing",
                "--continue-on-device-error",
                "--json",
                "--output",
                "/tmp/launchability.json",
                "--env",
                "TURBO_DEBUG_MEDIA_RELAY_ENABLED=0",
            ]
        )

        self.assertTrue(args.continue_on_device_error)
        self.assertTrue(args.terminate_existing)
        self.assertTrue(args.json)
        self.assertEqual("/tmp/launchability.json", args.output)
        self.assertEqual(["TURBO_DEBUG_MEDIA_RELAY_ENABLED=0"], args.env)

    def test_device_failure_summary_names_device_and_exit_code(self) -> None:
        device = device_app.Device(
            identifier="devicectl-id",
            udid="physical-udid",
            name="Mauricio's iPhone",
            model="iPhone",
            os_version="26.4",
            state="available",
            transport="usb",
            serial_number="serial",
            developer_mode="enabled",
        )

        summary = device_app.device_failure_summary(device, SystemExit(7))

        self.assertEqual("Mauricio's iPhone (physical-udid) exit=7", summary)

    def test_launch_result_classifies_locked_device(self) -> None:
        stderr = (
            "ERROR: The application failed to launch.\n"
            "BSErrorCodeDescription = Locked\n"
            "Unable to launch com.rounded.Turbo because the device was not, or could not be, unlocked.\n"
        )

        reason = device_app.classify_launch_result(1, "", stderr)
        message = device_app.launch_result_message("", stderr)

        self.assertEqual("locked", reason)
        self.assertIn("Unable to launch", message)

    def test_launch_result_classifies_locked_device_from_devicectl_json(self) -> None:
        diagnostics = (
            "The request was denied by service delegate (SBMainWorkspace) for reason: "
            'Locked ("Unable to launch com.rounded.Turbo because the device was not, '
            'or could not be, unlocked").\n'
            "BSErrorCodeDescription\n"
            "Locked"
        )

        reason = device_app.classify_launch_result(1, "", "", diagnostics)
        message = device_app.launch_result_message("", "", diagnostics)

        self.assertEqual("locked", reason)
        self.assertIn("Unable to launch", message)

    def test_launch_json_diagnostic_text_flattens_nested_coredevice_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "launch.json"
            path.write_text(
                """
                {
                  "error": {
                    "userInfo": {
                      "NSUnderlyingError": {
                        "error": {
                          "userInfo": {
                            "BSErrorCodeDescription": {"string": "Locked"},
                            "NSLocalizedFailureReason": {
                              "string": "Unable to launch com.rounded.Turbo because the device was not, or could not be, unlocked."
                            }
                          }
                        }
                      }
                    }
                  }
                }
                """,
                encoding="utf-8",
            )

            diagnostics = device_app.launch_json_diagnostic_text(path)

        self.assertIn("BSErrorCodeDescription", diagnostics)
        self.assertIn("Locked", diagnostics)
        self.assertIn("Unable to launch", diagnostics)

    def test_launch_result_classifies_disconnect(self) -> None:
        reason = device_app.classify_launch_result(
            1,
            "",
            "ERROR: The device disconnected immediately after connecting.",
        )

        self.assertEqual("device-disconnected", reason)

    def test_launch_result_classifies_coredevice_unavailable(self) -> None:
        diagnostics = (
            "CoreDeviceService was unable to locate a device matching the requested "
            "device identifier. (DeviceIdentifier: ecid_123)"
        )

        reason = device_app.classify_launch_result(1, "", "", diagnostics)
        message = device_app.launch_result_message("", "", diagnostics)

        self.assertEqual("device-unavailable", reason)
        self.assertIn("unable to locate", message)

    def test_lock_state_parser_accepts_json_for_connected_devices(self) -> None:
        args = device_app.parse_args_for_test(["lock-state-connected", "--json"])

        self.assertTrue(args.json)
        self.assertEqual("lock-state-connected", args.command)

    def test_lock_state_summary_marks_current_lock_unknown_when_devicectl_omits_field(self) -> None:
        device = device_app.Device(
            identifier="devicectl-id",
            udid="physical-udid",
            name="Mauricio's iPhone",
            model="iPhone",
            os_version="26.4",
            state="connected",
            transport="localNetwork",
            serial_number="serial",
            developer_mode="enabled",
        )

        summary = device_app.device_summary(device)
        self.assertEqual("Mauricio's iPhone", summary["name"])

        self.assertIsNone(
            device_app.first_present(
                {
                    "deviceIdentifier": "devicectl-id",
                    "passcodeRequired": True,
                    "unlockedSinceBoot": True,
                },
                ["locked", "isLocked", "deviceLocked"],
            )
        )

    def test_diagnostics_file_relative_paths_uses_readable_file_entries(self) -> None:
        payload = {
            "result": {
                "files": [
                    {
                        "name": "beepbeep-diagnostics.log",
                        "relativePath": "beepbeep-diagnostics.log",
                        "resources": {"isDirectory": False, "isReadable": True},
                    },
                    {
                        "name": "nested.log",
                        "relativePath": "nested/nested.log",
                        "resources": {"isDirectory": False, "isReadable": True},
                    },
                    {
                        "name": "Diagnostics",
                        "relativePath": "Diagnostics",
                        "resources": {"isDirectory": True, "isReadable": True},
                    },
                    {
                        "name": "unreadable.log",
                        "relativePath": "unreadable.log",
                        "resources": {"isDirectory": False, "isReadable": False},
                    },
                ]
            }
        }

        self.assertEqual(
            ["beepbeep-diagnostics.log", "nested/nested.log"],
            device_app.diagnostics_file_relative_paths(payload),
        )

    def test_diagnostics_file_relative_paths_rejects_unsafe_paths(self) -> None:
        payload = {
            "result": {
                "files": [
                    {
                        "name": "safe.log",
                        "relativePath": "safe.log",
                        "resources": {"isDirectory": False, "isReadable": True},
                    },
                    {
                        "name": "escape.log",
                        "relativePath": "../escape.log",
                        "resources": {"isDirectory": False, "isReadable": True},
                    },
                    {
                        "name": "escape.log",
                        "relativePath": "nested/../escape.log",
                        "resources": {"isDirectory": False, "isReadable": True},
                    },
                ]
            }
        }

        self.assertEqual(["safe.log"], device_app.diagnostics_file_relative_paths(payload))


if __name__ == "__main__":
    unittest.main()
