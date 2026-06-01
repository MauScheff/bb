# Testing Guide

Repo-specific proof rules. Prefer `just` wrappers; they encode simulator locking, selector validation, and zero-test guardrails.

## TurboEngine package tests

Use `ENGINE.md` for the engine proof model. Prefer package tests or headless engine scenarios before simulator scenarios for Conversation, Connection, Talk Turn, PTT, media, and low-level transport rules in `client/ios/Packages/TurboEngine`.

```bash
just engine-test
just engine-scenario foreground_transmit_receive
just engine-scenario 'fuzz_case:12345:0'
just engine-scenario-local foreground_transmit_receive http://localhost:8090/s/turbo
just engine-scenario-diff-local foreground_transmit_receive http://localhost:8090/s/turbo
just engine-fuzz-corpus
just engine-fuzz-local 12345 500 http://localhost:8090/s/turbo
just reliability-fuzz-local-overnight 12345 500 http://localhost:8090/s/turbo
just engine-invariant-coverage
just engine-trace-replay /tmp/turbo-engine-trace.json
```

Direct package command when debugging SwiftPM itself:

```bash
swift test --package-path client/ios/Packages/TurboEngine
```

`engine-scenario` uses in-memory simulation. `engine-scenario-local` and `engine-fuzz-local` use `turbo.serveLocal`; start it first:

```bash
just serve-local
```

Use live-local engine proof when the reducer rule is covered but production-like backend route semantics matter without launching iOS. The local backend remains the Unison source of truth; the Swift in-memory backend is only a simulation/fuzz adapter.

Engine fuzz artifacts live under `/tmp/turbo-engine-fuzz/`; replay generated cases with `just engine-scenario 'fuzz_case:<seed>:<index>'`. Persistent fuzz coverage lives in `client/ios/Packages/TurboEngine/Fixtures/fuzz-corpus.json` and runs through `just engine-fuzz-corpus`.

Engine traces turn app/device failures into headless reducer replays:

```bash
just engine-trace-extract /tmp/turbo-debug/<run>/merged-diagnostics.txt /tmp/turbo-engine-trace.json
just engine-trace-replay /tmp/turbo-engine-trace.json
```

Current app diagnostics uploads should include `engineTrace` in the structured diagnostics envelope. A fresh shake/manual report without an extractable trace is a diagnostics export or intake regression unless the build predates trace upload. Use the available facts to construct the smallest engine scenario only after the exact trace path is unavailable.

Named engine scenarios now cover foreground audio, background/locked wake buffering, network migration, Connection fallback, packet loss/reorder/duplicate, ordered-lane backlog drop, stale stops, and active-transmit cleanup when receiver addressability disappears.

Before choosing a proof for any simulator, physical-device, production, or shake-report failure, classify the boundary using [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md): `crosses engine boundary`, `app adapter/effect executor`, `distributed integration`, or `Apple/PTT/audio boundary`. A device-found failure that crosses the engine boundary must become an engine trace replay, scenario, fuzz case, or package test before physical retest is treated as proof.

Do not prove engine core behavior through raw `xcodebuild` or physical devices when a package-level reducer, adapter, scenario, or fuzz proof can cover the invariant.

## Proof Selection Table

| Claim | Preferred proof | Notes |
| --- | --- | --- |
| Engine reducer transition, invariant, or effect list | `just engine-test` | Add or update a package test under `client/ios/Packages/TurboEngine/Tests`. |
| Synthetic audio, mocked PTT, lifecycle, network faults, or transport fallback | `just engine-scenario <name>` | Use in-memory simulation when backend semantics are irrelevant. |
| Same story against local backend routes | `just serve-local`, then `just engine-scenario-local <name>` | Fails clearly when `turbo.serveLocal` is unavailable. |
| In-memory versus real local backend drift | `just engine-scenario-diff-local <name>` | Compares scenario outputs across both backend ports. |
| Engine interleaving or timing family | `just engine-fuzz-local <seed> <count>` or `just engine-fuzz-corpus` | Save the artifact path and seed; promote stable failures to deterministic tests. |
| Broad local overnight reliability sweep | `just reliability-fuzz-local-overnight <seed> <count>` | Runs live-local engine fuzz before simulator fuzz; simulator seed artifacts include strict diagnostics and engine trace replay. |
| Physical/simulator bug that crosses the engine boundary | `just engine-trace-extract ...`, then `just engine-trace-replay ...` | Convert replayable failures into package tests or named scenarios. |
| Active engine invariant coverage | `just engine-invariant-coverage` | Fails when active `engine.*` invariants lack executable proof references. |
| App-side projection, adapter, or effect executor | `just swift-test-target <name>` | Use Swift Testing selectors through the wrapper, not raw partial `xcodebuild` selectors. |
| PTT readiness adapter interleavings | `just ptt-readiness-fuzz` | Deterministic single-agent fuzz over backend/PTT/audio adapter evidence before simulator fuzz. |
| Audio packet/playout interleavings | `just audio-packet-fuzz` | Deterministic Swift fuzz over capture framing, E2EE audio envelopes, all incoming audio transports, stale/duplicate packet delivery, reorder, loss, FEC/PLC, playback scheduler late-IO/cushion drain, wake activation buffering, checked-in device-derived audio incidents, corpus state mutations, and playout drain before physical audio retest. |
| Fast Relay packet/TCP media boundary | `cargo test --manifest-path backend/relay/Cargo.toml` plus `just swift-test-target mediaRelayDatagramCodecRoundTripsPacketAudioFrame` and `just swift-test-target mediaRelayCodecRoundTripsTcpAudioFrame` | Server proves stream/datagram participants do not clobber each other, TCP audio is rejected on QUIC control streams, and Swift proves packet/TCP frame wire shape. |
| Packet media app classification | `just swift-test-target incomingAudioPlaybackGateDoesNotDropPacketMediaAsOrderedBacklog` plus `just swift-test-target incomingAudioTransportSelectsTransportPolicy` | Direct QUIC and Fast Relay packet media must map to unordered capability and must not use ordered-backlog drop policy. |
| Packet media send liveness | `just swift-test-target packetMediaPayloadSplitterKeepsEncryptedDatagramsUnderObservedPathMaximum`, `just swift-test-target audioChunkSenderAllowsBoundedInFlightPacketSends`, and `just swift-test-target transportPoliciesSelectDistinctPlaybackAndSenderProfiles` | Direct QUIC and Fast Relay datagram audio stay below observed path MTU, allow bounded concurrent packet sends, and avoid ordered/reliable send-completion stalls. |
| Opus voice payload and playout behavior | Opus voice proof set below | Proves 48 kHz/20 ms framing, Opus envelope compatibility with legacy PCM, capability-gated send policy, reorder/duplicate/late/missing-frame handling, PLC fallback, adaptive cushion growth/reset, and packet datagram budget. |
| Ordered media lane backlog/drop behavior | `just engine-scenario websocket_ordered_burst_drop`, `just engine-scenario fast_relay_tcp_ordered_burst_drop`, `just swift-test-target incomingAudioPlaybackGateDropsOrderedBacklogCatchupFrames`, `just swift-test-target incomingAudioPlaybackGateDropsFastRelayTcpBacklogCatchupFrames` | Prove both reducer policy and app boundary execution for `media-relay-tcp` and `relay-websocket` before physical retest. |
| App PushToTalk transmit startup gate | `just swift-test-target appleGatedWarmDirectQuicDefersCaptureUntilAppleAudioActivation` plus focused lane tests | Prove backend lease, Apple system transmit, and Apple audio activation before capture/live projection. |
| Distributed app/backend journey | `just simulator-scenario <name>` | Use when the app target, scenario DSL, websocket faults, or merged diagnostics add necessary evidence. |
| Broad pre-device confidence | `just reliability-gate-regressions` | Includes `just engine-test` plus focused app/tooling checks. |
| Apple/PTT/audio boundary | `just device-run`, `just device-test`, or `just device-ui-test` plus `just reliability-intake...` on failure | Retest only after shared failures have a lower-level proof. |

Opus voice proof set:

```bash
just swift-test-target voiceFrameAccumulatorEmitsExactTwentyMillisecondFrames
just swift-test-target opusVoiceCodecEncodesDecodesTwentyMillisecondFrameAndPLC
just swift-test-target voiceAudioFramePayloadCodecRoundTripsOpusV2AndLegacyPCM
just swift-test-target voiceMediaNegotiationRequiresFreshPeerOpusEvidence
just swift-test-target transportPoliciesSelectLaneSpecificOpusEncodingPolicies
just swift-test-target incomingPacketLossEstimateFeedsOutgoingPacketLaneOpusPolicy
just swift-test-target adaptiveVoicePlayoutBufferHandlesReorderDuplicatesLateFramesAndPLC
just swift-test-target adaptiveVoicePlayoutBufferAcceptsStartupReorderBeforeCushionStarts
just swift-test-target adaptiveVoicePlayoutCushionGrowsAfterUnderrunAndResetsForNewTransmit
just swift-test-target opusV2PacketMediaPayloadFitsDirectAndFastRelayDatagrams
```

## Swift Testing selectors

`TurboTests` uses Swift Testing (`import Testing`, `@Test`), not classic XCTest selectors. Raw `xcodebuild -only-testing` can build successfully while selecting zero tests.

Concept suites live under `TurboTests/` by glossary owner: `BeepTests`, `ReadinessTests`, `ConversationTests`, `ConnectionTests`, `DeviceTests`, `TalkTurnTests`, `DiagnosticsTests`, `BackendContractTests`, and `SimulatorScenarioTests`. Keep `TurboTests.swift` as a stub. Add shared helpers to the owner-specific support file, not to a new catch-all monolith:

| Support file | Scope |
| --- | --- |
| `TurboTestFixtureSupport.swift` | shared Conversation/backend fixture builders and diagnostics projections |
| `TurboTestPropertySupport.swift` | deterministic property/fuzz generators |
| `TurboTestDeviceDoubles.swift` | Device/PTT/media test doubles |
| `SimulatorScenarioSupport.swift` | simulator scenario DSL, runtime, expectations, and artifacts |
| `BackendContractTestSupport.swift` | backend contract manifest readers and payload helpers |

Preferred targeted command:

```bash
just swift-test-target audioOutputPreferenceCyclesBetweenSpeakerAndPhone
```

The wrapper resolves the suite, invokes exact `-only-testing`, uses the serialized simulator lane, and fails if the requested function never appears in output.
Do not run multiple `just swift-test-target` commands in parallel against the same simulator; Xcode can kill one run before test bootstrap and produce a false harness failure. Run targeted Swift tests sequentially.

Preferred full-bundle command:

```bash
just swift-test-suite
```

The full-suite wrapper runs all `TurboTests`, reuses the serialized simulator lane, writes an `.xcresult`, and fails on zero executed tests.

If raw `xcodebuild` is unavoidable, include suite type and trailing function parentheses:

```bash
xcodebuild test \
  -project client/ios/Turbo.xcodeproj \
  -scheme BeepBeep \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  '-only-testing:TurboTests/DeviceTests/audioOutputPreferenceCyclesBetweenSpeakerAndPhone()' \
  -skip-testing:TurboUITests \
  CODE_SIGNING_ALLOWED=NO
```

Selector shape:

```text
TurboTests/<Swift Testing suite type>/<test function>()
```

Examples:

```text
TurboTests/DeviceTests/audioOutputPreferenceCyclesBetweenSpeakerAndPhone()
TurboTests/HatTilingTests/levelTwoHatTextureIsDeterministic()
```

Do not use partial or XCTest-style selectors for Swift Testing proofs:

```text
-only-testing:TurboTests/
-only-testing:TurboTests/DeviceTests/<test function>
-only-testing:TurboTests/<test function>
```

These forms can succeed with zero selected Swift Testing tests.

Proof requires at least one:

- `just swift-test-target <name>` exits successfully
- `just swift-test-suite` exits successfully
- the log contains Swift Testing lines such as `Test <name>() started` and `Test <name>() passed`
- an xcresult summary reports `totalTestCount` greater than zero:

```bash
xcrun xcresulttool get test-results summary --path <ResultBundle>.xcresult
```

Do not count successful build, `Testing started`, or a classic XCTest summary alone.

## Physical-device tests

Physical-device tests are a hardware boundary lane, not a replacement for engine, Swift adapter, backend, or simulator proofs.

Use:

```bash
just device-list
just device-run <device>
just device-diagnostics <device>
just device-test <device>
just device-test-target <device> audioOutputPreferenceCyclesBetweenSpeakerAndPhone
just device-ui-test <device>
```

`device-diagnostics` copies the app's persisted diagnostics directory from the app container before or after a physical run. `device-test` defaults to `TurboTests` and skips `TurboUITests`. `device-ui-test` runs the UI test target for end-to-end device automation. Test commands write `.xcresult` bundles under `/tmp/turbo-device-app/` and fail if the result reports zero tests.

Set `TURBO_DEVICE_ALLOW_PROVISIONING_UPDATES=1` only when the operator intentionally allows Xcode signing asset updates for a local device run.

## Diagnostic Contract Tests

Critical reliability seams should use diagnostic contracts for assumptions that should hold and can be checked at runtime. See `INVARIANTS.md`.

At authoring time, a contract documents an assumption: current attempt, pending ACK expectation, queued audio eventually reaches a terminal outcome. It becomes diagnostic evidence when violated.

Use `DiagnosticsContracts` factories from `Turbo/DiagnosticsContracts.swift` for durable hot-path contracts. They keep `contractName`, `contractKind`, `invariantID`, `scope`, and core evidence fields consistent across runtime diagnostics, tests, and `shared/contracts/app_contract_manifest.json`.

Use `DiagnosticsStore.requireContract(...)` for guard-style checks that can fail closed immediately:

```swift
guard diagnostics.requireContract(
    hasCurrentAttempt,
    kind: .precondition,
    invariantID: "transmit.stale_startup_side_effect",
    scope: .local,
    subsystem: .pushToTalk,
    message: "stale transmit startup completion rejected",
    metadata: ["attemptId": attemptID]
) else {
    return
}
```

Use `DiagnosticsStore.recordContractViolation(...)` after observing a failure when no useful guard return exists.

Contract tests should assert both outputs:

- `DiagnosticsStore.invariantViolations` contains the expected `contractName`, `invariantID`, `scope`, `contractKind`, and correlation metadata.
- `DiagnosticsStore.entries` contains the corresponding `.error` diagnostic with the same `contractName` and `invariantID` metadata.

Also test the non-violating path when practical. A held contract should not emit an invariant violation or error entry.

Focused proof examples:

```bash
just swift-test-target diagnosticsContractGuardRecordsInvariantAndEntry
just swift-test-target diagnosticsContractGuardDoesNotRecordWhenConditionHolds
just swift-test-target firstAudioPlaybackAckWithoutExpectationRecordsContractViolation
```

For media/Conversation event bridges, test both layers when possible:

- the low-level producer emits `contractKind`, `invariantID`, `scope`, and compact correlation fields
- the owning view model or diagnostics bridge turns that metadata into a structured invariant violation
