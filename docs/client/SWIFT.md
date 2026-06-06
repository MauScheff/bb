# Swift / iOS Guide

Status: active guide.
Canonical home for: Swift/iOS architecture rules, app-side implementation expectations, component boundaries, and Swift ADT patterns.
Related docs: [`ENGINE.md`](/Users/mau/Development/bb/ENGINE.md) owns the TurboEngine architecture contract; [`APP_STATE.md`](/Users/mau/Development/bb/docs/client/APP_STATE.md) owns app-visible state semantics; [`SWIFT_DEBUGGING.md`](/Users/mau/Development/bb/docs/client/SWIFT_DEBUGGING.md) owns simulator/device/PTT/audio debugging loops.

Use `WORKFLOW.md` for ownership/proof rules. Use `ENGINE.md` before changing Conversation, Connection, Talk Turn, PTT, media, or low-level transport state; app-side Swift should adapt around engine snapshots/effects, not compete with engine truth.

Related operational docs:

- [`SWIFT_DEBUGGING.md`](/Users/mau/Development/bb/docs/client/SWIFT_DEBUGGING.md)
- [`VOICE_MEDIA_CORE.md`](/Users/mau/Development/bb/docs/client/VOICE_MEDIA_CORE.md) for binary voice packet framing, playout engine boundaries, replay, and rollout rules
- [`TESTING.md`](/Users/mau/Development/bb/TESTING.md) for targeted Swift Testing command syntax and zero-test guardrails
- [`APP_STATE.md`](/Users/mau/Development/bb/docs/client/APP_STATE.md) for app-visible Conversation projections and happy-path transition examples

## Rules

- Improve the shape of the system as you solve a bug. If the fix leaves the overall structure worse, it is not done.
- Do not call work "hardening" until the design is sound and the broken invariant is named.
- Views render derived state and emit intents; domain types own business rules; infrastructure clients own integration details.
- Decouple by responsibility: Friend relationship state, selected Conversation projection, backend client/Connection path, PushToTalk, media delivery, diagnostics/tooling.
- Remove demo or scaffold runtime behavior once a production-backed path exists. Do not keep hardcoded mock contact flows in the shipping path.
- Build observability into the feature: actionable logs, structured diagnostics, relevant IDs, verification tooling, automatic capture when useful.
- Use red/green TDD for core logic when practical.
- For targeted Swift `@Test` runs, use `just swift-test-target <name>` by default. If raw `xcodebuild -only-testing` is unavoidable, use `TurboTests/<suite>/<function>()` with the trailing parentheses and confirm a nonzero Swift Testing test executed.
- Test at the highest-leverage seam: pure reducer/domain first, coordinator/client second, physical device only for unsimulated Apple/PTT/audio surfaces.
- For iOS refactors, prefer extracting small dedicated types/files over growing `ContentView.swift`.
- For backend and app integration, keep repeatable probes and smoke checks checked into the repo when they materially improve iteration speed.

## App Architecture Pattern

- UI renders derived state and emits user intents.
- UI gestures, backend updates, websocket signals, Apple/PTT callbacks, timers, lifecycle changes, and media callbacks become typed events.
- Reducers/transition functions decide valid next state.
- Diagnostics explain transitions, invariants, and rejected events.
- Put Conversation, Connection, Talk Turn, PTT, media, and low-level transport rules in `Packages/TurboEngine` when they do not require iOS frameworks.
- Keep Apple PushToTalk, AVAudio, SwiftUI, notifications, backend client, Fast Relay, and Direct QUIC as adapters that execute typed engine effects and feed typed events back.

## Voice Media Codec State

Current voice-media encoding is app-side. Backend media routes still carry opaque payload strings, and E2EE still wraps the full media payload string before Direct QUIC, Fast Relay, or websocket relay transport. Binary packet media and the modular playout engine are specified in [`VOICE_MEDIA_CORE.md`](/Users/mau/Development/bb/docs/client/VOICE_MEDIA_CORE.md). No Unison schema migration is required for the current Opus path.

Authoritative Swift seams:

| File | Responsibility |
| --- | --- |
| [`Turbo/VoiceMediaCodec.swift`](/Users/mau/Development/bb/client/ios/Turbo/VoiceMediaCodec.swift) | voice codec capability types, Opus v2 envelope codec, binary voice packet codec, 48 kHz frame accumulator, Opus codec seam, PCM sample-rate conversion, playout engine seam, adaptive playout buffer |
| [`Turbo/PCMWebSocketMediaSession.swift`](/Users/mau/Development/bb/client/ios/Turbo/PCMWebSocketMediaSession.swift) | AVAudio capture/playback, outbound codec policy execution, legacy PCM fallback, receive decode, adaptive playout scheduling, codec diagnostics |
| [`Turbo/PTTViewModel+VoiceMediaCapabilities.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+VoiceMediaCapabilities.swift) | Friend/Participant codec capability evidence, outbound media policy selection, active Conversation policy updates |
| [`Turbo/ConversationParticipantTelemetry.swift`](/Users/mau/Development/bb/client/ios/Turbo/ConversationParticipantTelemetry.swift) | Conversation Participant telemetry and receiver-ready capability advertisement |
| [`Turbo/DirectQuicProbeController.swift`](/Users/mau/Development/bb/client/ios/Turbo/DirectQuicProbeController.swift) | Direct QUIC receiver-prewarm capability advertisement |

Sender flow:

1. Capture is converted to canonical 48 kHz mono signed 16-bit PCM.
2. `VoiceFrameAccumulator` emits exact 20 ms frames: 960 samples, 1 channel, 1,920 bytes.
3. `VoiceMediaNegotiator` selects `opus-v2` whenever the local build has the Opus codec. Peer capability evidence is still recorded for diagnostics, but outbound audio does not downgrade because stale readiness evidence says nothing useful about a current Turbo client.
4. Opus sends use one `turbo-audio-frame-v2` envelope per 20 ms frame. Packet media lanes send one encoded frame per datagram and use a lane-derived `OpusVoiceEncodingPolicy`; ordered fallback lanes batch short frame bursts into one ordered transport payload so backend WebSocket/TCP fallback is not asked to carry 50 media messages per second.
5. Legacy PCM remains decodable for old diagnostics, replay corpora, and defensive inbound compatibility while that plumbing is unwound. Current clients should not produce outbound legacy PCM when Opus is available.

Audio transport and codec matrix:

| Diagnostic lane | Media primitive | Codec policy | Playout profile | Notes |
| --- | --- | --- | --- | --- |
| `direct-quic` | Direct device-to-device QUIC datagram packet media | Opus v2 when local codec support exists | `directLowLatency` | Control stays on the ordered QUIC message/control path. Live audio uses datagrams. Best packet lanes use 40 kbps Opus and enable FEC only from observed loss. |
| `media-relay-packet` | Fast Relay QUIC datagram packet media over UDP | Opus v2 when local codec support exists | `fastRelayBalanced` | Preferred relay fallback when Direct QUIC is unavailable. QUIC stream audio is not used. Best packet lanes use 40 kbps Opus and enable FEC only from observed loss. |
| `media-relay-tcp` | Fast Relay TCP/TLS ordered stream media | Opus v2 when local codec support exists | `websocketContinuity` | Explicit degraded fallback when relay QUIC/datagrams cannot connect. Stale ordered backlog must be dropped. Reliable fallback Opus uses 32 kbps with FEC off. |
| `relay-websocket` | Backend websocket ordered stream media | Opus v2 when local codec support exists | `websocketContinuity` | Guaranteed compatibility path; backend still sees only opaque payload strings. Reliable fallback Opus uses 32 kbps with FEC off. |

Fast Relay QUIC is considered selected only after both the ordered QUIC control stream joins and the separate QUIC datagram media join receives a `datagram-join-ack`. If datagram join times out or fails, the app falls back to explicit Fast Relay TCP/TLS (`media-relay-tcp`) or backend websocket rather than sending hidden QUIC-stream audio.

Opus v2 payload shape:

| Field | Value |
| --- | --- |
| `kind` | `turbo-audio-frame-v2` |
| `codec` | `opus` |
| `frameIndex` | monotonic 20 ms voice-frame index |
| `sampleRate` | `48000` |
| `channels` | `1` |
| `frameDurationMs` | `20` |
| `features` | `plc`, plus `in-band-fec` when the active `OpusVoiceEncodingPolicy` enables FEC |
| `payload` | base64 Opus packet |

Receiver flow:

- `VoiceAudioFramePayloadCodec.decodeTransportFrames` accepts both Opus v2 envelopes and legacy base64 PCM payloads.
- Legacy PCM is resampled from the older 16 kHz shape into the current 48 kHz playback format.
- Opus frames enter `AdaptiveVoicePlayoutBuffer`, keyed by `frameIndex`, and decode in scheduled playout order.
- Startup cushions are lane-specific: Direct QUIC targets 4 frames, Fast Relay packet targets 5, websocket fallback targets 7, and wake/background continuity targets 8. Opus startup can begin after the lane timeout with a partial cushion so sparse or reordered live packets do not block playback indefinitely.
- Duplicate and late frames are dropped. Missing frames use next-packet FEC for the immediately previous frame when available, otherwise native PLC. Repeated gaps increase adaptive cushion up to 3 extra frames for the current transmit.
- Each remote transmit prepare starts a fresh receive playout epoch. Warm receive media sessions must reset Opus frame-index state and pending playback for the new transmit so frame indexes from an earlier press cannot delay or drop the next press.
- Opus decoded frames are packet/jitter-gated by the active playout engine. After Apple/system audio activation, AVAudio may apply a startup-only scheduler cushion before the player node starts so the first audible buffers are not starved; once the node is playing, Opus frames schedule without an extra transport cushion. Legacy PCM uses the lane-specific transport cushion.
- Receive playback admission must not await first-playback ACK sends, ingress summaries, or diagnostics. Those are post-admission observers; an Apple-gated startup burst must continue entering playout while control-plane and reporting work catches up on a separate bounded queue.
- Playback drain/readiness is based on AVAudioPlayerNode `.dataPlayedBack` completion so the UI remains blocked while scheduled audio is still audible.

Current codec implementation:

- `OpusVoiceCodec` is the dependency seam.
- The current implementation uses the vendored `Vendor/Opus/TurboOpus.xcframework`, built from upstream Xiph `libopus` by `scripts/build_libopus_xcframework.sh`.
- `OpusVoiceEncodingPolicy` is a pure value derived from the selected Connection lane and observed packet loss.
- Encoder configuration is mono 48 kHz PCM, 20 ms frames, `OPUS_APPLICATION_VOIP`, complexity 10, voice signal, constrained VBR, DTX off, fullband bandwidth, 16-bit LSB depth, native PLC, and lane-specific bitrate/FEC/loss hints.
- Direct QUIC and Fast Relay packet lanes use 40 kbps Opus, packet-loss hints from the rolling incoming sequence-gap estimate, and in-band FEC only when observed loss is at least 3%.
- TCP/WebSocket fallback lanes use 32 kbps Opus with packet-loss hint 0 and in-band FEC off; ordered backlog policy handles stale speech instead.
- Local capabilities advertise Opus v2, PLC, and `in-band-fec`. Outbound audio uses Opus v2 whenever the local codec is available; legacy PCM remains only as an inbound/replay compatibility decoder while older diagnostics and corpora exist.

## Swift ADT Patterns

| ADT concept | Swift construct |
| --- | --- |
| Sum type: one of many variants | `enum`, usually with associated values |
| Product type: fields that coexist | `struct` |
| Recursive type | `indirect enum` |
| Open/extensible family | `protocol` |

Closed variants use enums with associated values:

```swift
enum Result<Value> {
    case success(Value)
    case failure(Error)
}
```

Handle enums with exhaustive `switch`. Prefer associated values over optional fields when data exists only in one case.

Use structs for product data:

```swift
struct User {
    let id: Int
    let name: String
}
```

Prefer immutable stored values. Use `indirect enum` for recursive domains:

```swift
indirect enum Tree<Value> {
    case empty
    case node(left: Tree, value: Value, right: Tree)
}
```

Use protocols only when cases must be open/extensible:

```swift
protocol Shape {
    func area() -> Double
}
```

Mental model:

- `AND` means `struct`.
- `OR` means `enum`.
- `Optional` is already an ADT: `.none` or `.some(Wrapped)`.
- Invalid states should be unrepresentable.

Good:

```swift
enum Payment {
    case cash
    case card(number: String)
}
```

Bad:

```swift
struct Payment {
    let isCash: Bool
    let cardNumber: String?
}
```

## Current app shape

`ENGINE.md` is authoritative for Conversation, Connection, Talk Turn, PTT, media, and low-level transport truth. App types act as typed projections or platform adapters.

- [`Turbo/ConversationDomain.swift`](/Users/mau/Development/bb/client/ios/Turbo/ConversationDomain.swift)
  - authoritative selected Conversation derivation
  - relationship ADTs, selected Conversation detail ADTs, and projection rules
  - primary action derivation and reconciliation rules
- [`Turbo/SelectedConversationProjection.swift`](/Users/mau/Development/bb/client/ios/Turbo/SelectedConversationProjection.swift)
  - selected Conversation reducer / coordinator state
- [`Turbo/TransmitCoordinator.swift`](/Users/mau/Development/bb/client/ios/Turbo/TransmitCoordinator.swift)
  - transmit lifecycle reducer
- [`Turbo/PTTCoordinator.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTCoordinator.swift)
  - system PushToTalk reducer / callback state
- [`Turbo/PTTSystemClient.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTSystemClient.swift)
  - real-device Apple PushToTalk client plus simulator shim
- [`Turbo/BackendClient.swift`](/Users/mau/Development/bb/client/ios/Turbo/BackendClient.swift)
  - backend HTTP + websocket transport
- [`Turbo/BackendSyncCoordinator.swift`](/Users/mau/Development/bb/client/ios/Turbo/BackendSyncCoordinator.swift)
  - summaries, Beeps/Beep Threads, channel refresh, and reconciliation triggers
- [`Turbo/BackendCommandCoordinator.swift`](/Users/mau/Development/bb/client/ios/Turbo/BackendCommandCoordinator.swift)
  - open Friend / connect / accept Beep / disconnect orchestration
- [`Turbo/AppDiagnostics.swift`](/Users/mau/Development/bb/client/ios/Turbo/AppDiagnostics.swift)
  - structured diagnostics timeline and transcript export
- [`Turbo/VoiceMediaCodec.swift`](/Users/mau/Development/bb/client/ios/Turbo/VoiceMediaCodec.swift)
  - app-side voice codec, Opus v2 envelope, frame accumulator, and adaptive playout primitives
- [`Turbo/PCMWebSocketMediaSession.swift`](/Users/mau/Development/bb/client/ios/Turbo/PCMWebSocketMediaSession.swift)
  - AVAudio media adapter, outbound codec policy execution, receive decode/playout, and legacy PCM fallback

`ContentView.swift` is not the authority for Conversation or Connection logic. New behavior belongs in domain types, coordinators, or typed integration seams first.
