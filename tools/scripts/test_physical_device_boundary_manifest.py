#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import physical_device_boundary_manifest
import physical_device_boundary_proof


class PhysicalDeviceBoundaryManifestTests(unittest.TestCase):
    def test_complete_artifact_derives_manifest_that_validator_accepts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact = self._write_merged_artifact(root, self._complete_anchor_text())
            artifacts = [physical_device_boundary_manifest.read_artifact(str(artifact))]
            devices = physical_device_boundary_manifest.devices_from_artifacts(artifacts)

            manifest = physical_device_boundary_manifest.build_manifest(artifacts, devices)
            result = physical_device_boundary_proof.validate_cells(manifest, root / "manifest.json")

        self.assertEqual(["iphone-a", "iphone-b"], devices)
        self.assertTrue(all(cell["status"] == "pass" for cell in manifest["cells"]))
        self.assertTrue(all(cell["status"] == "pass" for cell in result))

    def test_incomplete_artifact_keeps_cells_pending(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact = self._write_merged_artifact(root, "PTT audio session activated", devices=["iphone-a"])
            artifacts = [physical_device_boundary_manifest.read_artifact(str(artifact))]
            devices = physical_device_boundary_manifest.devices_from_artifacts(artifacts)

            manifest = physical_device_boundary_manifest.build_manifest(artifacts, devices)
            result = physical_device_boundary_proof.validate_cells(manifest, root / "manifest.json")

        self.assertEqual(["iphone-a"], devices)
        self.assertTrue(all(cell["status"] == "pending" for cell in manifest["cells"]))
        self.assertTrue(all(cell["status"] == "fail" for cell in result))

    def test_explicit_devices_can_complete_text_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact = root / "merged-diagnostics.txt"
            artifact.write_text(self._complete_anchor_text(), encoding="utf-8")
            artifacts = [physical_device_boundary_manifest.read_artifact(str(artifact))]

            manifest = physical_device_boundary_manifest.build_manifest(
                artifacts,
                ["physical-sender", "physical-receiver"],
            )

        self.assertTrue(all(cell["status"] == "pass" for cell in manifest["cells"]))

    def test_since_filter_excludes_old_diagnostic_lines(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact = root / "merged-diagnostics.txt"
            artifact.write_text(
                "\n".join(
                    [
                        "[2026-05-31T21:00:00.000Z] Direct QUIC identity directQuicActive=true",
                        "[2026-05-31T21:00:01.000Z] Audio chunk received transport=direct-quic Playback buffer scheduled",
                    ]
                ),
                encoding="utf-8",
            )

            parsed = physical_device_boundary_manifest.read_artifact(
                str(artifact),
                since=physical_device_boundary_manifest.parse_utc_timestamp("2026-05-31T21:01:00Z"),
            )

        self.assertEqual("", parsed["text"])

    def test_physical_boundary_launch_profile_can_satisfy_transport_context(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            direct_artifact = root / "direct.txt"
            direct_artifact.write_text(
                "\n".join(
                    [
                        "Direct QUIC identity direct-quic identity",
                        "Physical boundary launch profile transport=direct-quic",
                        "Audio chunk received transport=direct-quic Playback buffer scheduled",
                    ]
                ),
                encoding="utf-8",
            )
            relay_artifact = root / "relay.txt"
            relay_artifact.write_text(
                "\n".join(
                    [
                        "Physical boundary launch profile transport=media-relay-forced",
                        "Backend transmit lease granted PTT audio session activated Starting audio capture",
                        "Audio chunk received transport=media-relay-tcp Playback buffer scheduled",
                    ]
                ),
                encoding="utf-8",
            )
            artifacts = [
                physical_device_boundary_manifest.read_artifact(str(direct_artifact)),
                physical_device_boundary_manifest.read_artifact(str(relay_artifact)),
            ]

            manifest = physical_device_boundary_manifest.build_manifest(
                artifacts,
                ["iphone-a", "iphone-b"],
            )

        by_name = {cell["name"]: cell for cell in manifest["cells"]}
        self.assertTrue(by_name["direct-quic-media"]["context"]["Direct QUIC run configuration active"])
        self.assertTrue(by_name["fallback-relay-audio"]["context"]["fallback relay run configuration active"])

    def test_incoming_push_boundary_metadata_satisfies_lockscreen_wake_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact = root / "lockscreen.txt"
            artifact.write_text(
                "\n".join(
                    [
                        "wake-capable wakeReady wakeReadiness",
                        "Application entered background",
                        "Incoming PTT push received receiverState=background lockState=unlocked",
                        "Incoming PTT push received PTT audio session activated",
                        "Incoming PTT push received Playback buffer scheduled",
                    ]
                ),
                encoding="utf-8",
            )
            artifacts = [physical_device_boundary_manifest.read_artifact(str(artifact))]

            manifest = physical_device_boundary_manifest.build_manifest(
                artifacts,
                ["iphone-a", "iphone-b"],
            )

        by_name = {cell["name"]: cell for cell in manifest["cells"]}
        self.assertTrue(
            by_name["lockscreen-apns-wake"]["evidence"][
                "incoming push received on locked/background receiver"
            ]
        )
        self.assertEqual("pass", by_name["lockscreen-apns-wake"]["status"])

    def test_wake_timing_logs_satisfy_lockscreen_activation_and_playback(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact = root / "lockscreen-current.txt"
            artifact.write_text(
                "\n".join(
                    [
                        "wake-capable wakeReady wakeReadiness",
                        "protected-data-will-become-unavailable",
                        "Incoming PTT push received applicationState=background receiverState=locked",
                        "PTT audio session activated applicationState=UIApplicationState(rawValue: 2) pendingWakeChannelUUID=BC6717CB-9891-5AAB-BBA3-788A9688A096",
                        "Wake receive timing incomingWakeActivationState=systemActivated stage=system-audio-activation-observed",
                        "Wake receive timing incomingWakeActivationState=systemActivated stage=first-playback-buffer-scheduled pcmSilent=false",
                        "Wake receive timing incomingWakeActivationState=systemActivated stage=playback-node-started",
                    ]
                ),
                encoding="utf-8",
            )
            artifacts = [physical_device_boundary_manifest.read_artifact(str(artifact))]

            manifest = physical_device_boundary_manifest.build_manifest(
                artifacts,
                ["iphone-a", "iphone-b"],
            )

        by_name = {cell["name"]: cell for cell in manifest["cells"]}
        self.assertEqual("pass", by_name["lockscreen-apns-wake"]["status"])
        self.assertTrue(
            by_name["lockscreen-apns-wake"]["evidence"][
                "PTT audio session activated after wake"
            ]
        )
        self.assertTrue(
            by_name["lockscreen-apns-wake"]["evidence"]["lock-screen playback verified"]
        )

    def _write_merged_artifact(
        self,
        root: Path,
        text: str,
        *,
        devices: list[str] | None = None,
    ) -> Path:
        device_ids = devices if devices is not None else ["iphone-a", "iphone-b"]
        payload = {
            "reports": [
                {
                    "handle": f"@device{index}",
                    "deviceId": device_id,
                    "snapshot": {"selectedConversationPhase": "ready"},
                }
                for index, device_id in enumerate(device_ids)
            ],
            "mergedTimeline": text,
        }
        path = root / "merged-diagnostics.json"
        path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        return path

    def _complete_anchor_text(self) -> str:
        return "\n".join(
            [
                "selectedConversationPhase ready receiver-ready Connected",
                "Requesting Apple system transmit in parallel with backend lease",
                "Backend transmit lease granted",
                "System transmit began",
                "PTT audio session activated",
                "Signal received peer type=transmit-start",
                "Audio chunk received transport=direct-quic",
                "Playback buffer scheduled",
                "transmit-stop selectedConversationPhase ready",
                "wake-capable wakeReady wakeReadiness",
                "Application entered background",
                "Incoming PTT push received background",
                "wake systemActivated Playback buffer scheduled",
                "Direct QUIC identity direct-quic identity",
                "directQuicActive=true",
                "source=direct-quic direct-quic-data-channel",
                "Media relay TCP ordered fallback connected",
                "mediaRelayForced=true",
                "Starting audio capture",
                "Audio chunk received transport=media-relay-tcp Playback buffer scheduled",
            ]
        )


if __name__ == "__main__":
    unittest.main()
