import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "tools" / "scripts" / "audio_media_core_replay.py"


class AudioMediaCoreReplayTests(unittest.TestCase):
    def test_valid_event_log_replays_summary(self) -> None:
        payload = {
            "schemaVersion": 1,
            "sessionID": "session-a",
            "engineMode": "shadow-legacy-scheduled",
            "maximumEventCount": 8,
            "events": [
                {
                    "packetArrived": {
                        "epoch": 1,
                        "frameIndex": 10,
                        "sequenceNumber": 20,
                        "sentAtMilliseconds": 1000,
                        "receivedAtNanoseconds": 2000,
                        "packetSizeBytes": 96,
                    }
                },
                {
                    "packetAdmitted": {
                        "epoch": 1,
                        "frameIndex": 10,
                        "admission": "accepted",
                        "bufferDepthFrames": 1,
                    }
                },
                {
                    "playoutTick": {
                        "epoch": 1,
                        "tickIndex": 1,
                        "playoutAtNanoseconds": 3000,
                        "desiredSampleTimestamp48k": 9600,
                    }
                },
                {
                    "playoutDecision": {
                        "epoch": 1,
                        "tickIndex": 1,
                        "decision": "play-received",
                        "frameIndex": 10,
                        "targetDelayMilliseconds": 80,
                        "bufferedFrameCount": 0,
                    }
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "voice-media-event-log.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), str(path)],
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            )

        summary = json.loads(result.stdout)
        self.assertEqual(summary["eventCount"], 4)
        self.assertEqual(summary["admissions"], {"accepted": 1})
        self.assertEqual(summary["decisions"], {"play-received": 1})

    def test_non_monotonic_ticks_fail(self) -> None:
        payload = {
            "schemaVersion": 1,
            "sessionID": "session-a",
            "engineMode": "swift-neteq-v1",
            "maximumEventCount": 8,
            "events": [
                {
                    "playoutTick": {
                        "epoch": 1,
                        "tickIndex": 2,
                        "playoutAtNanoseconds": 3000,
                        "desiredSampleTimestamp48k": 9600,
                    }
                },
                {
                    "playoutTick": {
                        "epoch": 1,
                        "tickIndex": 2,
                        "playoutAtNanoseconds": 4000,
                        "desiredSampleTimestamp48k": 19200,
                    }
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "voice-media-event-log.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), str(path)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-monotonic tickIndex", result.stderr)


if __name__ == "__main__":
    unittest.main()
