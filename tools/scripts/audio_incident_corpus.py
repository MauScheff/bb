#!/usr/bin/env python3
"""Extract replayable audio incident facts from merged diagnostics."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TIMELINE_RE = re.compile(r"^\[(?P<timestamp>[^\]]+)\] \[(?P<label>[^\]]+)\] (?P<body>.*)$")
MERGED_LINE_RE = re.compile(r"^\[(?P<subject>[^\]]+)\] \[(?P<label>[^\]]+)\] (?P<body>.*)$")
KEY_VALUE_RE = re.compile(r"(?P<key>[A-Za-z][A-Za-z0-9_]*)=(?P<value>\"[^\"]*\"|[^\s]+)")
SECTION_HEADER_RE = re.compile(
    r"^(STATE SNAPSHOT|STRUCTURED DIAGNOSTICS|STATE TIMELINE|INVARIANT VIOLATIONS|DIAGNOSTICS)$"
)


@dataclass(frozen=True)
class TimelineEvent:
    timestamp: datetime | None
    subject: str
    label: str
    body: str
    metadata: dict[str, str]


@dataclass
class IncidentBuilder:
    subject: str
    packet_deliveries: list[dict[str, Any]] = field(default_factory=list)
    voice_frame_deliveries: list[dict[str, Any]] = field(default_factory=list)
    scheduler_operations: list[dict[str, Any]] = field(default_factory=list)
    receive_queue_incidents: list[dict[str, Any]] = field(default_factory=list)
    outbound_transport_incidents: list[dict[str, Any]] = field(default_factory=list)
    source_messages: list[str] = field(default_factory=list)
    next_synthetic_sequence: int = 0
    last_packet_timestamp: datetime | None = None
    last_voice_timestamp: datetime | None = None

    def add_source_message(self, message: str) -> None:
        normalized = message[:240]
        if len(self.source_messages) < 24 and normalized not in self.source_messages:
            self.source_messages.append(normalized)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Merged diagnostics JSON or diagnostics transcript text.")
    parser.add_argument("--output", "-o", type=Path, required=True)
    parser.add_argument("--name", default="", help="Stable incident/corpus name.")
    parser.add_argument(
        "--allow-empty",
        action="store_true",
        help="Write an empty corpus instead of failing when no audio facts are found.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return run(
        source=args.source,
        output=args.output,
        name=args.name or args.source.stem,
        allow_empty=args.allow_empty,
    )


def run(*, source: Path, output: Path, name: str, allow_empty: bool) -> int:
    events = load_events(source)
    incidents = build_incidents(events, name=name or source.stem)
    if not incidents and not allow_empty:
        raise SystemExit("no replayable audio incident facts found")
    payload = {
        "schemaVersion": 1,
        "source": str(source),
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "incidents": incidents,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"audio incident corpus: {output}")
    print(f"incidents: {len(incidents)}")
    for incident in incidents:
        print(
            " - {name}: packets={packets} frames={frames} schedulerOps={ops} outbound={outbound}".format(
                name=incident["name"],
                packets=len(incident.get("packetDeliveries", [])),
                frames=len(incident.get("voiceFrameDeliveries", [])),
                ops=len(incident.get("schedulerOperations", [])),
                outbound=len(incident.get("outboundTransportIncidents", [])),
            )
        )
    return 0


def load_events(path: Path) -> list[TimelineEvent]:
    text = path.read_text(encoding="utf-8")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return events_from_transcript(text)
    if isinstance(payload, dict):
        return events_from_json(payload) + events_from_violations(payload) + events_from_reports(payload)
    return []


def events_from_json(payload: dict[str, Any]) -> list[TimelineEvent]:
    events: list[TimelineEvent] = []
    timeline = payload.get("timeline")
    if not isinstance(timeline, list):
        return events
    for item in timeline:
        if not isinstance(item, dict):
            continue
        line = item.get("line")
        if not isinstance(line, str):
            continue
        parsed = parse_merged_line(line)
        if parsed is None:
            continue
        subject, label, body = parsed
        events.append(
            TimelineEvent(
                timestamp=parse_timestamp(item.get("timestamp")),
                subject=subject,
                label=label,
                body=body,
                metadata=parse_metadata(body),
            )
        )
    return events


def events_from_reports(payload: dict[str, Any]) -> list[TimelineEvent]:
    events: list[TimelineEvent] = []
    reports = payload.get("reports")
    if not isinstance(reports, list):
        return events
    for report in reports:
        if not isinstance(report, dict):
            continue
        transcript = report.get("transcript")
        if not isinstance(transcript, str):
            continue
        handle = str(report.get("handle") or "unknown")
        for event in events_from_transcript(transcript):
            events.append(
                TimelineEvent(
                    timestamp=event.timestamp,
                    subject=handle if event.subject == "transcript" else event.subject,
                    label=event.label,
                    body=event.body,
                    metadata=event.metadata,
                )
            )
    return events


def events_from_violations(payload: dict[str, Any]) -> list[TimelineEvent]:
    events: list[TimelineEvent] = []
    seen: set[tuple[str, str, str, str]] = set()
    for key in ("violations", "currentViolations", "historicalViolations"):
        violations = payload.get(key)
        if not isinstance(violations, list):
            continue
        for violation in violations:
            if not isinstance(violation, dict):
                continue
            subject = str(violation.get("subject") or "unknown")
            invariant_id = str(violation.get("invariantId") or violation.get("contractName") or key)
            message = str(violation.get("message") or invariant_id)
            timestamp = parse_timestamp(violation.get("timestamp"))
            metadata = violation.get("metadata")
            if not isinstance(metadata, dict):
                metadata = {}
            normalized_metadata = {str(k): str(v) for k, v in metadata.items() if v is not None}
            dedupe_key = (
                subject,
                invariant_id,
                timestamp.isoformat() if timestamp else "",
                json.dumps(normalized_metadata, sort_keys=True),
            )
            if dedupe_key in seen:
                continue
            seen.add(dedupe_key)
            events.append(
                TimelineEvent(
                    timestamp=timestamp,
                    subject=subject,
                    label=f"invariant:{violation.get('scope') or 'local'}",
                    body=f"{invariant_id} {message}",
                    metadata=normalized_metadata,
                )
            )
    return events


def events_from_transcript(text: str) -> list[TimelineEvent]:
    sections = split_sections(text)
    diagnostics = sections.get("DIAGNOSTICS", text)
    events: list[TimelineEvent] = []
    for line in diagnostics.splitlines():
        match = TIMELINE_RE.match(line)
        if not match:
            continue
        body = match.group("body")
        events.append(
            TimelineEvent(
                timestamp=parse_timestamp(match.group("timestamp")),
                subject="transcript",
                label=match.group("label"),
                body=body,
                metadata=parse_metadata(body),
            )
        )
    return events


def split_sections(transcript: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current_header: str | None = None
    for raw_line in transcript.splitlines():
        line = raw_line.rstrip("\n")
        if SECTION_HEADER_RE.match(line):
            current_header = line
            sections[current_header] = []
            continue
        if current_header is not None:
            sections[current_header].append(line)
    return {header: "\n".join(lines).strip() for header, lines in sections.items()}


def parse_merged_line(line: str) -> tuple[str, str, str] | None:
    match = MERGED_LINE_RE.match(line)
    if not match:
        return None
    return match.group("subject"), match.group("label"), match.group("body")


def parse_metadata(body: str) -> dict[str, str]:
    return {
        match.group("key"): match.group("value").strip('"')
        for match in KEY_VALUE_RE.finditer(body)
    }


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    normalized = value.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


def build_incidents(events: list[TimelineEvent], name: str) -> list[dict[str, Any]]:
    builders: dict[str, IncidentBuilder] = {}
    for event in sorted(events, key=lambda item: item.timestamp or datetime.min.replace(tzinfo=timezone.utc)):
        if not is_audio_event(event):
            continue
        builder = builders.setdefault(event.subject, IncidentBuilder(subject=event.subject))
        builder.add_source_message(event.body)
        add_packet_delivery(builder, event)
        add_voice_frame_delivery(builder, event)
        add_scheduler_operations(builder, event)
        add_receive_queue_incident(builder, event)
        add_outbound_transport_incident(builder, event)

    incidents: list[dict[str, Any]] = []
    for index, builder in enumerate(builders.values()):
        if not has_replayable_content(builder):
            continue
        incident: dict[str, Any] = {
            "name": sanitize_name(f"{name}_{index}_{builder.subject}"),
            "subject": builder.subject,
            "sourceMessages": builder.source_messages,
            "packetDeliveries": builder.packet_deliveries,
            "voiceFrameDeliveries": builder.voice_frame_deliveries,
            "schedulerOperations": compact_scheduler_operations(builder.scheduler_operations),
            "receiveQueueIncidents": builder.receive_queue_incidents,
            "outboundTransportIncidents": builder.outbound_transport_incidents,
        }
        incidents.append(incident)
    return incidents


def is_audio_event(event: TimelineEvent) -> bool:
    body = event.body
    return any(
        marker in body
        for marker in [
            "Audio chunk received",
            "Incoming audio ingress summary",
            "Direct QUIC audio payload received",
            "Dropped incoming audio frame before playback",
            "Skipped first audio playback ACK because playback was not accepted",
            "active receive epoch had an excessive gap between accepted audio chunks",
            "active receive epoch had a gap in accepted audio sequence numbers",
            "Incoming audio payload was delayed in the local receive queue",
            "media.incoming_audio_queue_delay",
            "Opus playout buffer updated",
            "Deferred playback node start until IO cycle",
            "Playback node still waiting for IO cycle",
            "Playback node started after IO cycle wait",
            "Buffered playback buffer for playout cushion",
            "Started playback after playout cushion",
            "Playback buffer scheduled",
            "Playback node started",
            "Playback node startup reasserted",
            "Playback node reasserted after audio route change",
            "Outbound audio transport send was slow",
            "Dropped stale outbound audio transport payload",
            "media.outbound_audio_transport_backpressure_drop",
            "media.outbound_audio_transport_slow_send_drop",
            "media.outbound_audio_transport_send_slow",
        ]
    )


def add_packet_delivery(builder: IncidentBuilder, event: TimelineEvent) -> None:
    if not any(
        marker in event.body
        for marker in [
            "Audio chunk received",
            "Incoming audio ingress summary",
            "Direct QUIC audio payload received",
            "Dropped incoming audio frame before playback",
            "active receive epoch had a gap in accepted audio sequence numbers",
            "Incoming audio payload was delayed in the local receive queue",
            "media.incoming_audio_queue_delay",
        ]
    ):
        return
    metadata = event.metadata
    transport = normalize_transport(metadata.get("transport") or metadata.get("incomingTransport"))
    if transport is None:
        return
    sequence_number = parse_int(
        metadata.get("encryptedSequenceNumber")
        or metadata.get("directQuicSequenceNumber")
        or metadata.get("sequenceNumber")
        or metadata.get("sequence")
    )
    if sequence_number is None:
        sequence_number = builder.next_synthetic_sequence
        builder.next_synthetic_sequence += 1
    else:
        builder.next_synthetic_sequence = max(builder.next_synthetic_sequence, sequence_number + 1)

    builder.packet_deliveries.append(
        {
            "sequenceNumber": sequence_number,
            "transport": transport,
            "deltaFrames": delta_frames(builder.last_packet_timestamp, event.timestamp),
        }
    )
    builder.last_packet_timestamp = event.timestamp


def add_receive_queue_incident(builder: IncidentBuilder, event: TimelineEvent) -> None:
    body = event.body
    metadata = event.metadata
    invariant_id = (
        metadata.get("invariantID")
        or metadata.get("contractName")
        or metadata.get("invariantId")
        or body.split(maxsplit=1)[0]
    )
    if invariant_id != "media.incoming_audio_queue_delay" and (
        "Incoming audio payload was delayed in the local receive queue" not in body
    ):
        return

    transport = normalize_transport(metadata.get("transport") or metadata.get("incomingTransport"))
    sequence_number = parse_int(
        metadata.get("encryptedSequenceNumber")
        or metadata.get("directQuicSequenceNumber")
        or metadata.get("sequenceNumber")
        or metadata.get("sequence")
    )
    local_queue_delay_ms = parse_int(metadata.get("localQueueDelayMs"))
    sender_clock_age_ms = parse_int(metadata.get("senderClockAgeMs"))
    threshold_ms = parse_int(
        metadata.get("thresholdMs")
        or metadata.get("senderClockAgeThresholdMs")
        or metadata.get("liveBacklogThresholdMs")
    )

    incident: dict[str, Any] = {
        "action": metadata.get("action") or live_queue_action_from_reason(metadata.get("reason")),
        "reason": metadata.get("reason"),
    }
    if sequence_number is not None:
        incident["sequenceNumber"] = sequence_number
    if transport is not None:
        incident["transport"] = transport
    if local_queue_delay_ms is not None:
        incident["localQueueDelayMs"] = local_queue_delay_ms
    if sender_clock_age_ms is not None:
        incident["senderClockAgeMs"] = sender_clock_age_ms
    if threshold_ms is not None:
        incident["thresholdMs"] = threshold_ms
    receive_epoch = parse_int(metadata.get("receiveEpoch"))
    if receive_epoch is not None:
        incident["receiveEpoch"] = receive_epoch
    stage = metadata.get("stage")
    if stage:
        incident["stage"] = stage

    if not any(
        key in incident
        for key in (
            "sequenceNumber",
            "transport",
            "localQueueDelayMs",
            "senderClockAgeMs",
            "thresholdMs",
            "receiveEpoch",
        )
    ):
        return

    if incident not in builder.receive_queue_incidents:
        builder.receive_queue_incidents.append(incident)


def live_queue_action_from_reason(reason: str | None) -> str | None:
    if reason == "expired-live-backlog":
        return "dropped-expired-live-backlog"
    if reason == "expired-sender-clock-age":
        return "dropped-expired-sender-clock-age"
    return reason


def add_voice_frame_delivery(builder: IncidentBuilder, event: TimelineEvent) -> None:
    metadata = event.metadata
    frame_index = parse_int(metadata.get("frameIndex"))
    if frame_index is None:
        return
    builder.voice_frame_deliveries.append(
        {
            "frameIndex": frame_index,
            "deltaFrames": delta_frames(builder.last_voice_timestamp, event.timestamp),
            "isFlushFrame": False,
        }
    )
    builder.last_voice_timestamp = event.timestamp


def add_scheduler_operations(builder: IncidentBuilder, event: TimelineEvent) -> None:
    body = event.body
    profile = playback_profile_from_event(event)

    if "Deferred playback node start until IO cycle" in body:
        builder.scheduler_operations.extend(
            [
                {"type": "setIOCycleAvailable", "available": False},
                {
                    "type": "receive",
                    "playbackProfile": profile,
                    "cushionPolicy": "alreadyCushioned",
                },
                {"type": "startWaitPoll"},
            ]
        )
    elif "Playback node still waiting for IO cycle" in body:
        count = max(1, min(parse_int(event.metadata.get("attempt")) or 1, 128))
        builder.scheduler_operations.append({"type": "startWaitPoll", "count": count})
    elif "Playback node started after IO cycle wait" in body:
        builder.scheduler_operations.extend(
            [
                {"type": "setIOCycleAvailable", "available": True},
                {"type": "startWaitPoll"},
            ]
        )
    elif "Buffered playback buffer for playout cushion" in body:
        builder.scheduler_operations.extend(
            [
                {"type": "setIOCycleAvailable", "available": True},
                {
                    "type": "receive",
                    "playbackProfile": profile,
                    "cushionPolicy": "applyTransportCushion",
                },
            ]
        )
    elif "Started playback after playout cushion" in body:
        builder.scheduler_operations.append({"type": "cushionTimeout"})
    elif "Playback buffer scheduled" in body:
        if not builder.scheduler_operations:
            builder.scheduler_operations.extend(
                [
                    {"type": "setIOCycleAvailable", "available": True},
                    {
                        "type": "receive",
                        "playbackProfile": profile,
                        "cushionPolicy": "alreadyCushioned",
                    },
                ]
            )
    elif "Playback node started" in body:
        builder.scheduler_operations.append({"type": "playbackNodeStarted"})
    elif "Playback node startup reasserted" in body or "Playback node reasserted after audio route change" in body:
        builder.scheduler_operations.append({"type": "startupReassertion"})


def add_outbound_transport_incident(builder: IncidentBuilder, event: TimelineEvent) -> None:
    body = event.body
    metadata = event.metadata
    invariant_id = (
        metadata.get("invariantID")
        or metadata.get("contractName")
        or metadata.get("invariantId")
        or body.split(maxsplit=1)[0]
    )
    incident_type: str | None = None
    if (
        invariant_id == "media.outbound_audio_transport_send_slow"
        or "Outbound audio transport send was slow" in body
    ):
        incident_type = "slowSend"
    elif (
        invariant_id == "media.outbound_audio_transport_slow_send_drop"
        or metadata.get("reason") == "outbound-transport-slow-send"
    ):
        incident_type = "slowSendDrop"
    elif (
        invariant_id == "media.outbound_audio_transport_backpressure_drop"
        or metadata.get("reason") == "outbound-transport-backpressure"
    ):
        incident_type = "backpressureDrop"

    if incident_type is None:
        return
    if not any(
        key in metadata
        for key in (
            "droppedPayloadCount",
            "elapsedMilliseconds",
            "maximumPendingPayloads",
            "payloadLength",
            "pendingPayloadCount",
            "reason",
        )
    ):
        return

    incident: dict[str, Any] = {"type": incident_type}
    for key in (
        "droppedPayloadCount",
        "elapsedMilliseconds",
        "maximumPendingPayloads",
        "payloadLength",
        "pendingPayloadCount",
    ):
        value = parse_int(metadata.get(key))
        if value is not None:
            incident[key] = value
    reason = metadata.get("reason")
    if reason:
        incident["reason"] = reason
    digest = metadata.get("transportDigest")
    if digest:
        incident["transportDigest"] = digest
    if incident not in builder.outbound_transport_incidents:
        builder.outbound_transport_incidents.append(incident)


def playback_profile_from_event(event: TimelineEvent) -> str:
    explicit = event.metadata.get("playbackProfile")
    if explicit:
        return normalize_playback_profile(explicit)
    transport = normalize_transport(event.metadata.get("transport"))
    if transport == "directQuic":
        return "lowLatency"
    if transport in {"mediaRelayPacket", "mediaRelayTcp"}:
        return "fastRelayBalanced"
    if transport == "relayWebSocket":
        return "relayJitterBuffered"
    return "lowLatency"


def normalize_playback_profile(value: str) -> str:
    compact = value.replace(".", "").replace("_", "").replace("-", "").lower()
    if "wake" in compact:
        return "wakeBackgroundContinuity"
    if "fastrelay" in compact:
        return "fastRelayBalanced"
    if "relayjitter" in compact or "websocket" in compact:
        return "relayJitterBuffered"
    return "lowLatency"


def normalize_transport(value: str | None) -> str | None:
    if not value:
        return None
    compact = value.replace(".", "").replace("_", "").replace("-", "").lower()
    if compact in {"directquic", "direct"}:
        return "directQuic"
    if compact in {"mediarelaypacket", "fastrelaypacket", "relaypacket"}:
        return "mediaRelayPacket"
    if compact in {"mediarelaytcp", "fastrelaytcp", "relaytcp", "tcprelay"}:
        return "mediaRelayTcp"
    if compact in {"relaywebsocket", "websocket", "relayed", "http"}:
        return "relayWebSocket"
    return None


def parse_int(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def delta_frames(previous: datetime | None, current: datetime | None) -> int:
    if previous is None or current is None:
        return 1
    elapsed = max(0.0, (current - previous).total_seconds())
    return max(0, min(500, round(elapsed / 0.02)))


def compact_scheduler_operations(operations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    compacted: list[dict[str, Any]] = []
    for operation in operations:
        if (
            compacted
            and operation.get("type") == "startWaitPoll"
            and compacted[-1].get("type") == "startWaitPoll"
        ):
            compacted[-1]["count"] = int(compacted[-1].get("count", 1)) + int(operation.get("count", 1))
        else:
            compacted.append(operation)
    return compacted


def has_replayable_content(builder: IncidentBuilder) -> bool:
    return bool(
        builder.packet_deliveries
        or builder.voice_frame_deliveries
        or builder.scheduler_operations
        or builder.receive_queue_incidents
        or builder.outbound_transport_incidents
    )


def sanitize_name(value: str) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9_]+", "_", value.strip())
    sanitized = re.sub(r"_+", "_", sanitized).strip("_")
    return sanitized or "audio_incident"


if __name__ == "__main__":
    raise SystemExit(main())
