# Voice Media Core

Status: active architecture contract.
Canonical home for: binary voice packet framing, playout engine boundaries, media-core diagnostics, replay, and rollout rules.
Related docs: [`SWIFT.md`](/Users/mau/Development/bb/docs/client/SWIFT.md), [`SWIFT_DEBUGGING.md`](/Users/mau/Development/bb/docs/client/SWIFT_DEBUGGING.md), [`TESTING.md`](/Users/mau/Development/bb/TESTING.md).

## Goals

- Keep Turbo's media core RTC-grade without importing an RTC session stack.
- Keep packet media byte-oriented on hot paths: no JSON or base64 inside Direct QUIC or Fast Relay datagram audio.
- Make invalid playout states unrepresentable where practical.
- Keep the new engine swappable with the current adaptive playout implementation until shadow evidence proves the new path.
- Make failures replayable from local artifacts before simulator or device retest.

The Apple voice-processing audit is intentionally out of scope for this document's current implementation track.

## Packet Contract

`VoicePacketV1` is the binary Opus packet type. It is valid only when all invariants hold:

| Field | Rule |
| --- | --- |
| codec | Opus only |
| sample rate | 48 kHz |
| channels | mono |
| duration | 20 ms |
| payload | non-empty, bounded Opus packet bytes |
| frame index | monotonic within a receive epoch |
| sample timestamp | 48 kHz media ticks, normally `frameIndex * 960` |

Binary wire shape:

| Offset | Field |
| --- | --- |
| 0 | magic `TVP1` |
| 4 | version `1` |
| 5 | codec `1` for Opus |
| 6..7 | flags |
| 8..9 | header length |
| 10..17 | frame index, big-endian `UInt64` |
| 18..25 | 48 kHz sample timestamp, big-endian `UInt64` |
| 26..27 | payload length, big-endian `UInt16` |
| 28..31 | reserved zero bytes |
| 32.. | Opus payload |

Inbound decoding rejects malformed packets at the boundary. Downstream playout and decode code should receive a validated `VoicePacketV1`, not loose packet metadata.

## Capability And Rollout

Capabilities advertise `turbo-voice-packet-v1` alongside existing Opus, PLC, and FEC support. The old `turbo-audio-frame-v2` JSON envelope and legacy PCM remain decodable for compatibility, replay fixtures, and old diagnostics.

`VoiceMediaCoreMode` chooses the active implementation:

| Mode | Behavior |
| --- | --- |
| `legacy-adaptive` | Current adaptive playout implementation schedules audio. |
| `swift-neteq-v1` | Swift NetEQ-inspired engine schedules audio with its own bounded packet buffer, startup gate, FEC/PLC gap recovery, large-gap resync, jitter-smoothed target delay, and metrics. |
| `shadow-legacy-scheduled` | `ShadowLegacyScheduledPlayoutEngine` keeps legacy authoritative, runs Swift NetEQ against the same validated packets with inert decode stubs, and reports scheduler divergence through `VoicePlayoutEngineMetrics.shadowDivergenceCount`. |

Local override:

- UserDefaults key: `TurboDebugVoiceMediaCoreMode`
- Live diagnostics UserDefaults key: `TurboDebugLiveVoiceMediaCoreMode`
- Launch argument: `-TurboDebugVoiceMediaCoreMode <mode>`
- Environment: `TURBO_DEBUG_VOICE_MEDIA_CORE_MODE=<mode>`

Live media sessions use `swift-neteq-v1`. Legacy and shadow modes remain constructible for compatibility tests, replay fixtures, and historical diagnostics, but live calls normalize stale legacy/shadow launch arguments or defaults back to Swift NetEQ. The diagnostics sheet no longer exposes live legacy/shadow selection.

Binary packet advertisement is controlled separately:

- UserDefaults key: `TurboDebugBinaryVoicePacketV1Enabled`
- Launch argument: `-TurboDebugBinaryVoicePacketV1Enabled <true|false>`
- Environment: `TURBO_DEBUG_BINARY_VOICE_PACKET_V1_ENABLED=<true|false>`

Binary packet advertisement is on by default for live media when Opus is available. Debug builds may explicitly disable it for a comparison cell.

Legacy PCM is not a live fallback. If Opus encode or codec setup fails, the live session drops the frame and emits `voice.media.no_live_legacy_pcm` evidence instead of switching to base64 PCM.

## Playout Algebra

The playout engine is a pull-driven module:

```text
packet arrival -> admission decision
playout tick   -> exactly one playout decision or hold
```

Closed states:

| Type | Variants |
| --- | --- |
| `VoicePlayoutPhase` | `idle`, `buffering`, `playing`, `draining` |
| `VoicePacketAdmission` | `accepted`, `duplicate`, `late`, `wrongEpoch`, `malformed` |
| `VoicePlayoutDecision` | `hold`, `playReceived`, `playFEC`, `playPLC`, `expand`, `preemptiveExpand`, `accelerate`, `resync` |

Pure modules own packet buffering, delay estimation, clock-drift estimation, and decision policy. Effect seams own Opus decode/FEC/PLC, diagnostics, and AVAudio scheduling.

The engine tracks sender media time, receiver monotonic time, and playout time separately. Drift correction is explicit through bounded accelerate and preemptive-expand decisions, not implicit buffer-depth side effects.

`SwiftNetEqPlayoutEngine` is the active Swift implementation for the `swift-neteq-v1` mode. It intentionally keeps the current `VoicePlayoutInsertResult` boundary so rollout can happen through the existing AVAudio scheduler while the internal packet buffer and delay estimator are independent from `AdaptiveVoicePlayoutBuffer`.

`ShadowLegacyScheduledPlayoutEngine` is the rollout comparison module. It returns only legacy scheduled PCM frames to AVAudio, so shadow mode cannot perturb playback with observer output. The observer path compares frame index, recovery type, duplicate/late/missing counts, FEC/PLC counts, and resync counts; target-delay differences are informational until shadow traces show stable parity.

## Replay And Diagnostics

`VoiceMediaEventLog` records a bounded sequence of:

- packet arrival
- send timestamp
- receive timestamp
- admission decision
- playout tick
- playout decision
- decode/recovery outcome
- route change
- scheduler late or underrun event

Compact media-core traces may be included in diagnostics. Full traces stay local or in explicit audio incident artifacts.

Done media-core failures should be reproducible through `just audio-media-core-replay <trace>` or promoted into `just audio-packet-fuzz` / targeted Swift tests before a physical device retest is treated as proof.

## Real-Time Safety

- No JSON/base64 in packet-media datagram hot paths.
- No blocking awaits in playout.
- Bounded packet sizes, queues, event logs, and diagnostics.
- Diagnostics on hot paths must be budgeted.
- AVAudio scheduling consumes already-decided PCM frames; it does not own jitter policy.

## Proof Lane

Use the narrowest proof first:

```bash
just swift-test-target voicePacketV1CodecRoundTripsOpusFrame
just swift-test-target voiceAudioFramePayloadCodecRoundTripsBinaryOpusPacket
just swift-test-target voicePacketV1RejectsMalformedHeaders
just swift-test-target voiceMediaCoreModeDefaultsLiveCallsToSwiftNetEq
just swift-test-target directQuicAudioPayloadAsyncQueueKeepsRealtimeAudioAheadOfDiagnosticsStorm
just swift-test-target legacyAdaptivePlayoutEngineConformsToVoicePlayoutEngineContract
just swift-test-target swiftNetEqPlayoutEngineConformsToVoicePlayoutEngineContract
just swift-test-target shadowLegacyScheduledPlayoutEngineConformsToVoicePlayoutEngineContract
just swift-test-target voicePlayoutEngineFactorySelectsSwappableEngines
just swift-test-target swiftNetEqPlayoutEngineRaisesTargetDelayAfterLateInterArrivalGap
just audio-packet-fuzz
cargo test --manifest-path backend/relay/Cargo.toml
just reliability-gate-regressions
```
