#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import audio_incident_corpus


class AudioIncidentCorpusExtractionTests(unittest.TestCase):
    def test_uniform_ingress_summary_and_ack_failure_become_packet_replay(self) -> None:
        payload = {
            "timeline": [
                {
                    "timestamp": "2026-05-29T10:00:00+00:00",
                    "line": (
                        "[@mau] [media] Incoming audio ingress summary "
                        "contactId=contact channelId=channel fromDeviceId=peer "
                        "transport=direct-quic sampleCount=1 acceptedCount=1 "
                        "droppedCount=0 playbackAcceptedCount=1 playbackRejectedCount=0 "
                        "maxLocalQueueDelayMs=7 freshnessDecision=accepted "
                        "playbackDecision=accepted source=direct-quic sequenceNumber=42"
                    ),
                },
                {
                    "timestamp": "2026-05-29T10:00:00.020000+00:00",
                    "line": (
                        "[@mau] [media] Skipped first audio playback ACK because playback was not accepted "
                        "contactId=contact channelId=channel fromDeviceId=peer "
                        "transport=direct-quic transportDigest=abc123"
                    ),
                },
                {
                    "timestamp": "2026-05-29T10:00:00.060000+00:00",
                    "line": (
                        "[@mau] [invariant:local] media.incoming_audio_sequence_gap "
                        "active receive epoch had a gap in accepted audio sequence numbers "
                        "contactId=contact channelId=channel incomingTransport=direct-quic "
                        "previousSequenceNumber=42 sequenceNumber=45 missingSequenceCount=2"
                    ),
                },
            ]
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "merged-diagnostics.json"
            output = Path(temp_dir) / "audio-incident-corpus.json"
            source.write_text(json.dumps(payload), encoding="utf-8")

            self.assertEqual(
                audio_incident_corpus.run(
                    source=source,
                    output=output,
                    name="device_response_silence",
                    allow_empty=False,
                ),
                0,
            )

            corpus = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(corpus["schemaVersion"], 1)
        self.assertEqual(len(corpus["incidents"]), 1)
        incident = corpus["incidents"][0]
        self.assertEqual(incident["subject"], "@mau")
        self.assertEqual(
            incident["packetDeliveries"],
            [
                {"deltaFrames": 1, "sequenceNumber": 42, "transport": "directQuic"},
                {"deltaFrames": 3, "sequenceNumber": 45, "transport": "directQuic"},
            ],
        )
        self.assertTrue(
            any("Skipped first audio playback ACK" in message for message in incident["sourceMessages"])
        )


if __name__ == "__main__":
    unittest.main()
