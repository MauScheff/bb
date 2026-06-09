# Turbo Engine

Status: active engine architecture guide.
Canonical home for: `TurboEngine` package architecture, algebraic engine state, reducer/effect boundaries, simulation, and app adapter rules.
Related docs: [`ENGINE_HUMANS.md`](/Users/mau/Development/bb/docs/product/ENGINE_HUMANS.md) is an agent-facing plain-language engine brief; [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md) owns the global state-machine and proof model; [`SWIFT.md`](/Users/mau/Development/bb/docs/client/SWIFT.md) owns app-side Swift architecture; [`APP_STATE.md`](/Users/mau/Development/bb/docs/client/APP_STATE.md) owns current app-visible projections; [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/bb/docs/reliability/STATE_MACHINE_TESTING.md) and [`SIMULATOR_FUZZING.md`](/Users/mau/Development/bb/docs/reliability/SIMULATOR_FUZZING.md) own simulator scenario mechanics.

Turbo Engine is the Foundation-only local Swift package that owns app-side Conversation, Connection, Talk Turn, Push-to-Talk, media, and low-level transport truth. The iOS app, headless scenarios, fuzzers, and live-local backend runners all drive the same engine through typed intents/events and execute returned effects outside the reducer.

The architecture shape is:

```text
UI / platform / backend callbacks
  -> typed TurboEngineIntent or TurboEngineEvent
  -> TurboEngine reducer
  -> TurboEngineTransition(state, snapshot, effects, diagnostics, invariantViolations)
  -> external effect executors
  -> typed events back into the engine
```

## Package Layout

| Path | Responsibility |
| --- | --- |
| `Packages/TurboEngine/Package.swift` | declares `TurboEngine`, `TurboEngineSimulation`, and `turbo-engine` |
| `Sources/TurboEngine/TurboEngine.swift` | domain types, snapshots, intents/events, effects, reducers, diagnostics, invariants, backend port protocol |
| `Sources/TurboEngineSimulation/TurboEngineSimulation.swift` | synthetic media, virtual network faults, in-memory/live-local backend ports, scenario reports, runner helpers |
| `Sources/TurboEngineCLI` | engine scenario/fuzz command entrypoint |
| `Tests/TurboEngineTests` | fast package regressions; prefer before simulator scenarios |

`TurboEngine` imports only `Foundation`. Apple PushToTalk, AVAudio, SwiftUI, backend clients, Fast Relay, Direct QUIC, lifecycle plumbing, and notifications stay in app-side or simulation/external adapter targets.

## Authority

`TurboEngine` owns local authoritative truth for:

- selected Friend / selected Conversation lifecycle
- local Talk Turn transmit lifecycle
- remote receive lifecycle
- current Connection path phase and fallback/recovery
- app lifecycle as it affects playback and PTT activation
- PTT audio activation state
- scheduled synthetic playback facts needed by the reducer

The backend remains authoritative for shared control-plane facts such as Conversation membership, routes, Beeps/Beep Threads, readiness, wake targeting, and Talk Turn transmit grants. The backend is not ported to Swift. `InMemoryEngineBackendPort` exists only for synthetic simulation/fuzzing; live-local engine proof uses the Rust runtime plus Unison kernel through the self-hosted local route.

`PTTViewModel` is an adapter around:

- `var engine: TurboEngine`
- app-side effect executors
- observable fields derived directly from `TurboEngineSnapshot` and typed app projections

It must not be the source of truth for Conversation, Connection, Talk Turn, or media state when an engine path exists.

## Core API

The public core shape is intentionally small:

```swift
public struct TurboEngine {
    public private(set) var state: TurboEngineState
    public var snapshot: TurboEngineSnapshot { get }

    public mutating func send(_ intent: TurboEngineIntent) -> TurboEngineTransition
    public mutating func receive(_ event: TurboEngineEvent) -> TurboEngineTransition
}
```

Use `send(_:)` for local/user intents. Use `receive(_:)` for external backend, PTT, media, transport, lifecycle, and clock facts.

Every call returns state, snapshot, effects, diagnostics, and invariant violations:

```swift
public struct TurboEngineTransition: Equatable, Sendable {
    public let state: TurboEngineState
    public let snapshot: TurboEngineSnapshot
    public let effects: [TurboEngineEffect]
    public let diagnostics: [EngineDiagnostic]
    public let invariantViolations: [EngineInvariantViolation]
}
```

Reducers are total transition functions. Invalid inputs fail closed by preserving or moving to typed terminal/recovery state, recording an invariant violation, and returning needed diagnostics/effects. Do not crash or hide contradictions behind compatibility booleans.

## Algebraic State

Engine truth uses explicit phases with state-specific evidence:

| Phase type | Cases |
| --- | --- |
| `EngineConversationPhase` | `none`, `selected`, `requesting`, `incomingBeep`, `joining`, `joined`, `disconnecting`, `recovering` |
| `EngineTransmitPhase` | `idle`, `beginning`, `active`, `stopping`, `failed` |
| `EngineReceivePhase` | `idle`, `prepared`, `awaitingPTTActivation`, `receiving`, `draining`, `failed` |
| `EngineTransportPhase` | `fastRelay`, `directQuic`, `recovering`, `unavailable` |
| `EnginePTTAudioActivationState` | `inactive`, `activating`, `active`, `failed` |

Put data inside the case that owns it. For example, joined Conversation readiness belongs inside `JoinedConversationEvidence`, active Talk Turn transmit facts belong inside `TransmitEpoch`, and buffered wake playback belongs inside `WakeBufferedReceive`.

No internal boolean bundles, nullable state clusters, raw string statuses, or duplicated source-of-truth projections. If a capability cannot be proven, represent the missing proof:

```swift
public enum EngineReadiness<T: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    case unavailable(ReadinessMissingReason)
    case pending(ReadinessPendingReason)
    case ready(T)
}

public enum EngineCapability<T: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    case unsupported(CapabilityUnsupportedReason)
    case blocked(CapabilityBlockedReason)
    case available(T)
}
```

Every failure and recovery path should carry a typed reason. Every stale callback, duplicate chunk, transport migration, or delayed activation should be checked against attempt IDs, transmit IDs, channel IDs, device IDs, epochs, or typed evidence.

Friend receive addressability is explicit evidence, not a boolean. `ReceiverAddressability` is the existing engine type name; its cases are `foreground`, `wakeCapable`, and `unavailable(reason)`. Local transmit cannot begin, recover, or remain active without foreground or wake-capable receiver evidence; membership loss, wake-token revocation, and backend active-transmit clears must move active transmit into stop/idle instead of preserving a stale talking state.

Media capability is explicit evidence, not a transport label. `EngineMediaTransportCapability` distinguishes unordered packet media, ordered reliable media, reliable control, unavailable, and degraded states. Control traffic stays ordered/reliable; live audio uses sequence, timestamp, epoch, jitter, late-drop, duplicate-drop, and missing-frame skip semantics. Ordered media is limited to Fast Relay TCP/TLS fallback and must report backlog degradation instead of draining stale catch-up audio.

Current app lane mapping:

| Lane | Control semantics | Media semantics | Engine capability |
| --- | --- | --- | --- |
| Fast Relay packet | ordered reliable control stream | QUIC datagram packet media | `unorderedPacketMedia(.fastRelayPacketRelay)` |
| Fast Relay TCP | ordered reliable TCP/TLS stream | ordered reliable fallback | `orderedReliableMedia(.fastRelayTcpFallback)` |
| Direct QUIC packet | ordered reliable control stream | QUIC datagram packet media | `unorderedPacketMedia(.directQuicDatagram)` |

Direct QUIC does not send live audio over ordered reliable streams. Fast Relay packet media does not fall back to QUIC stream audio; when QUIC datagram media is unavailable, lane selection may use the explicitly named Fast Relay TCP/TLS fallback (`media-relay-tcp`). Runtime/backend transports must not be selected as live media. No ordered stream path may masquerade as packet media.

Voice codec capability is also explicit app-side evidence. The current app advertises `VoiceMediaCapabilities` in receiver-ready and Direct QUIC receiver-prewarm payloads, then sends `turbo-audio-frame-v2` Opus only after fresh Friend/Participant evidence proves Opus v2 support. Legacy PCM remains the fallback for older receivers, stale evidence, codec unavailability, and debugging. The engine owns media lane semantics; the iOS media adapter owns AVAudio conversion, Opus encode/decode, and adaptive playout execution.

Impossible engine states should not be constructible by normal app callers. Broad public initializers are acceptable only as temporary package/test scaffolding when reducer postconditions and focused tests cover the risk.

## Effects

The reducer does not perform side effects. It returns typed effects:

| Effect | Examples |
| --- | --- |
| `BackendEngineEffect` | runtime-control connect, begin/end transmit, fetch channel state |
| `PTTEngineEffect` | request begin/stop transmit, activate receive audio |
| `MediaEngineEffect` | start/stop capture, send live audio through a legal media lane, schedule playback, drop chunk with reason |
| `TransportEngineEffect` | prewarm path, fall back with recovery reason |
| `DiagnosticsEngineEffect` | record diagnostic or invariant violation |

Effect executors live outside the core. They translate an effect into Apple, AVAudio, backend, relay, QUIC, or diagnostics work, then feed completion/failure back as a typed `TurboEngineEvent`.

## Transmit Startup Contract

Transmit startup is a three-evidence gate, independent of transport lane:

1. Backend transmit lease granted with typed target device/transmit evidence.
2. Apple PushToTalk reports system transmit began for the current channel.
3. Apple PushToTalk/AVAudio reports the PTT audio session active for the same channel.

The effect executor requests Apple system transmit only after the backend Talk Turn lease is granted. It may prewarm runtime control, Fast Relay, Direct QUIC control/readiness, route computation, receiver prewarm, and remote-participant clearing before all evidence is present.

No lane may start microphone capture, send `transmit-start`, project local UI as `transmitting`, or use a provisional route as live capture authority until all three evidence items are current and the local press/epoch still matches. This applies equally to Fast Relay and Direct QUIC. Direct QUIC may preserve or warm the path, but it must not bypass the backend lease or Apple audio activation.

If Apple reports system transmit but audio activation does not arrive before the Apple-gated deadline, fail closed: stop system transmit, end or clean up the backend lease, mark the local press release-required, and do not send `transmit-start`.

## Snapshots And External Boundaries

`TurboEngineSnapshot` is the read model for UI and tests. It exposes algebraic phases plus derived typed readiness/capability:

- `localTalkCapability: EngineCapability<TransmitCapabilityEvidence>`
- `receiverReadiness: EngineReadiness<ReceiveReadinessEvidence>`
- `scheduledPlaybackCount`

App UI state should be derived from the snapshot or from named algebraic app projections. Do not reintroduce stored source-of-truth booleans such as `isJoined`, `isTransmitting`, or `activeChannelID` inside app reducers or view-model state.

Compatibility shapes are allowed only at fixed external boundaries:

- backend wire payloads that must decode older fields
- diagnostics or telemetry payloads already consumed by external tools
- Apple PushToTalk and AVAudio adapter facts that need platform-specific normalization

- Normalize external wire/platform facts into typed engine evidence before reducer logic depends on them.
- Keep collapsed booleans and raw strings out of engine state and internal app/backend boundaries.
- If a boundary must expose a compatibility field, derive it one way from typed state and cover the mapping with tests.
- Remove compatibility fields once the external consumer has migrated.

## Backend Ports

The engine boundary to the backend is `EngineBackendPort`:

```swift
public protocol EngineBackendPort {
    func seed(handle: String) async throws
    func reset(handle: String) async throws
    func connectRealtimeControl() async throws
    func sendControlCommand(_ command: EngineControlCommand) async throws -> EngineControlResponse
    func fetchChannelState(_ channelID: EngineChannelID) async throws -> EngineChannelState
}
```

`InMemoryEngineBackendPort` is a fault-injection simulation adapter. It must stay thin and intentionally incomplete; do not mirror backend business logic there. The live runtime backend port points the same runner at the active self-hosted runtime, normally `http://127.0.0.1:8091/s/turbo`, and is the preferred proof when backend route semantics matter. Live audio is not part of this backend port; engine media effects must be executed by media adapters over Direct QUIC or Fast Relay lanes.

Keep backend wire strings and compatibility shapes at this edge; normalize them into typed engine evidence before reducer logic depends on them.

The first live-local runner may support only a subset of routes. When a port method is intentionally unsupported, fail with a clear typed error instead of silently simulating success.

## Simulation

Engine simulations run without booting the iOS simulator.

| Component | Responsibility |
| --- | --- |
| `SyntheticMediaAdapter` | deterministic `EngineAudioChunk` generation |
| `VirtualNetwork` | delay/drop/duplicate/reorder delivery modeling |
| `EngineScenarioRunner` | named headless scenarios and seed-driven scenario selection |
| `EngineScenarioReport` | pass/fail, playback count, invariant IDs, notes |

Scenarios should cover the engine-level versions of:

- foreground transmit/receive with synthetic chunks
- locked/background receiver delayed PTT activation
- background audio buffering before activation, then deterministic drain
- active transmit network migration
- active transmit receiver addressability loss
- wake-token revocation clearing active transmit
- membership loss clearing active transmit
- idle network migration followed by transmit
- QUIC unavailable to Fast Relay fallback
- Fast Relay packet unavailable to explicit Fast Relay TCP/TLS fallback
- Direct QUIC send failure to relay fallback
- duplicate/reordered chunks without duplicate playback
- Direct datagram-style loss/reorder/duplicate with jitter deadline skip
- Fast Relay packet-style loss/reorder/duplicate with jitter deadline skip
- ordered fallback lanes dropping stale catch-up frames
  (`fast_relay_tcp_ordered_burst_drop`)
- stale stop rejected behind a newer transmit epoch
- incoming audio buffers before PTT activation, then drains
- no playback before active transmit epoch
- no playback after accepted stop

## Trace Replay

Every app-side engine boundary call is recorded as an `EngineTrace`: initial engine state plus ordered intents/events, emitted effects, resulting states, and invariant IDs. The trace is embedded in structured diagnostics and therefore in shake-to-report uploads.

Use trace replay when a physical-device, simulator, TestFlight, or production-like failure crosses the engine boundary:

```bash
just engine-trace-extract /tmp/turbo-debug/<run>/merged-diagnostics.txt /tmp/turbo-engine-trace.json
just engine-trace-replay /tmp/turbo-engine-trace.json
```

Replay must be deterministic. A mismatch means the local engine no longer reproduces the recorded behavior or the trace was collected from incompatible code. If replay passes and the behavior is wrong, convert the trace into the narrowest engine test, scenario, or fuzz corpus case before changing code.

## Proof Commands

Preferred recipes:

```bash
just engine-test
just engine-scenario foreground_transmit_receive
just engine-scenario 'fuzz_case:12345:0'
just engine-scenario-local foreground_transmit_receive http://127.0.0.1:8091/s/turbo
just engine-scenario-diff-local foreground_transmit_receive http://127.0.0.1:8091/s/turbo
just engine-fuzz-corpus
just engine-fuzz-local 12345 500 http://127.0.0.1:8091/s/turbo
just engine-invariant-coverage
just engine-trace-replay /tmp/turbo-engine-trace.json
```

Engine fuzz cases compose backend event ordering, PTT activation timing, lifecycle transitions, network migration, transport fallback, chunk drop/duplicate/reorder, jitter deadlines, ordered-backlog timing, stale epochs, and stop/start races. Each generated report includes a replay name such as `fuzz_case:<seed>:<index>` and writes artifacts under `/tmp/turbo-engine-fuzz/`. Promote stable failures into named scenarios, especially when they expose addressability, wake, media playout, or active-transmit cleanup rules.

The direct SwiftPM command is still useful when debugging package-level failures outside `just`:

```bash
swift test --package-path Packages/TurboEngine
```

For live-local proof, start the backend separately:

```bash
just self-hosted-up
just self-hosted-serve 127.0.0.1:8091
```

Then run the engine scenario/fuzz entrypoint against `http://127.0.0.1:8091/s/turbo`. Live-local engine commands should fail clearly when the backend is unavailable. Use `engine-scenario-diff-local` to compare the same scenario against in-memory simulation and the real local backend.

Existing broader gates still matter after app integration:

```bash
just swift-test-suite
just simulator-scenario-suite-hosted-smoke
just reliability-gate-regressions
```

Do not use physical devices as the first proof for engine logic. Physical devices are reserved for final Apple PushToTalk UI, microphone permission, background/lock-screen delivery, audio-session activation, and real capture/playback boundary validation.

## Migration Rules

When moving or adjusting app behavior in the engine-owned domains:

1. Convert UI gestures, backend updates, runtime-control notices, Apple callbacks, media callbacks, transport faults, lifecycle changes, and timers into typed engine intents/events.
2. Move the rule into the reducer or a focused engine domain helper.
3. Return typed effects instead of calling app services directly.
4. Derive `PTTViewModel` observable fields from `TurboEngineSnapshot` or typed app projections.
5. Keep raw backend wire strings, nullable payloads, and booleans in external adapters only.
6. Add the narrowest engine package test first, then add simulator/local-backend scenarios only when the journey needs distributed evidence.

When an old external representation and the algebraic engine disagree, fix the source-of-truth model or the fixed-boundary mapping. Do not add another precedence rule that preserves both as competing truths.

## Review Checklist

For engine changes, check:

- Core target imports only `Foundation`.
- Each lifecycle has an explicit phase enum.
- Readiness and capability decisions carry typed evidence or typed missing/blocking reasons.
- Failures and recoveries carry typed reasons.
- Reducers are total and side-effect-free.
- Stale completions are fenced by attempt, channel, transmit, or epoch identity.
- Old-shaped booleans are derived outside `TurboEngine` at fixed external boundaries only.
- Invariant violations include stable IDs and machine-readable metadata.
- Package tests cover reducer rules and adapter collapse points.
- Headless simulation is used before simulator or physical-device proof when possible.
