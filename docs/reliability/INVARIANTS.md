# Invariant Rules

Reliability bugs are broken named truths, not ad hoc log strings.

Use this for impossible-state reports involving distributed state, backend truth, app/backend contracts, selected Conversation projection, reconnect/retry behavior, or stale state. Use `WORKFLOW.md` for ownership/proof. Pair recoverable invalid states with `SELF_HEALING.md`.

## Core Model

An invariant has one stable identity in `invariants/registry.json`. Its executable check belongs at the narrowest seam that can prove the truth.

- `invariants/registry.json`: canonical index for ID, owner, detector location, evidence, repair policy, and proof status.
- Swift reducer/projection: app-owned transition and derived-state rules.
- Unison/backend route/service/projection: backend-owned shared truth.
- `scripts/merged_diagnostics.py`: pair and convergence rules that require multiple device/backend perspectives.
- TLA+ or fuzz oracle: protocol interleavings, stale facts, ordering, monotonicity, or convergence classes.

Do not build a generic registry-enforcement runtime. Most predicates need typed local context; place them at the state machine or backend seam that has it.

Use these terms when they help:

- `precondition`: what must be true before accepting an event or command.
- `postcondition`: what must be true after a transition, route, projection, or repair.
- `invariant`: what must remain true for every valid state in that subsystem.

Prefer typed state machines and total transitions that make illegal states unrepresentable. Use runtime invariant checks for cross-boundary, distributed, stale, or recoverable states the type system cannot rule out.

## Intake Workflow

Convert product/debug reports into durable rules:

- "Avery still sees Blake online after Blake disconnected."
- "Both devices look ready in the backend, but one UI is still stuck in outgoing Beep."
- "The sender can hold to talk even though the Friend is not actually Ready."

1. Restate the report as the broken truth, not the UI symptom.
2. Classify the boundary: `crosses engine boundary`, `app adapter/effect executor`, `distributed integration`, or `Apple/PTT/audio boundary`.
3. Identify the owner: app, backend, pair/convergence, Apple/PTT/audio boundary, or ambiguous in-flight state.
4. Choose or update a stable `invariantId`.
5. Add detection at the authoritative seam.
6. Emit expected/observed evidence with stable IDs.
7. Choose the narrowest proof lane.
8. Add bounded self-healing only when the state is provably invalid and safely repairable.
9. Fix the owning subsystem.
10. Verify with the selected proof and, when relevant, strict merged diagnostics.

The user should not need to ask separately for classification, registration, fuzzing, TLA+, scenarios, or proof selection.

## Contradiction Ledger

Diagnostics often expose more than the first visible bug. For physical-device, TestFlight, production, or shake-report investigations, keep a short ledger of every broken contract:

- preconditions that should have rejected stale or impossible input
- postconditions that should have been true after a transition or command
- liveness expectations such as "queued media is heard or explicitly declared lost"
- pair/convergence predicates that require two devices or device plus backend evidence
- observability gaps where a critical function cannot yet explain why it failed

For every ledger item, choose an outcome before calling the work done:

- map it to an existing registry entry and proof
- add a new registry entry, detector, and proof
- mark it as an explicit deferral with the reason and the evidence still needed

For device-found failures, do this boundary split before deferring: if the facts cross `TurboEngine`, encode an engine replay/scenario/fuzz case; if the engine model is green but adapter execution is wrong, add Swift adapter proof; defer only the remaining real Apple/PTT/audio surface.

Prefer detectors earlier than audible/user-visible failure. Critical paths should emit enough machine-readable facts for production-capable diagnosis and reject bad preconditions before accepting state.

## Critical Function Instrumentation

Critical functions are paths where silent failure becomes user-visible damage: transmit start/stop, audio capture/enqueue, transport send, receive scheduling, playback start/drain, Direct QUIC promotion/loss, wake targeting, token selection, backend readiness projection.

Annotate critical paths as touched, including adjacent old paths. Surface assumptions whose violation would make audio choppy, route state misleading, wake targeting stale, or backend truth contradictory.

Contracts are executable documentation of assumptions that should hold, not claims that they are currently broken.

Critical-path shape:

- check preconditions before accepting work, and emit an invariant when rejecting impossible or stale input
- record the command/epoch/attempt identity before starting asynchronous work
- record the postcondition after completion, including expected and observed facts
- emit compact liveness facts for queued, sent, received, scheduled, started, drained, dropped, and timed-out media
- include stable correlation fields: channel, contact, sender device, receiver device, attempt, transmit epoch, packet sequence or digest when safe

Goal: enough structured evidence to identify the broken contract and enough precondition checks to reject bad state before audio/UI degradation.

Contract kinds:

- `precondition`: input, state, epoch, token, peer, route, or authority must be valid before accepting work.
- `postcondition`: a command or transition completed but did not establish the promised state.
- `invariant`: a durable local, backend, pair, or convergence truth was contradicted.
- `liveness`: work was queued, started, or expected but did not progress to a terminal success/failure state in time.

In Swift, prefer the typed contract annotation path for critical seams:

- Add or reuse a stable invariant ID in `invariants/registry.json`.
- Add a `DiagnosticsContractSpec` factory under `DiagnosticsContracts` in `Turbo/DiagnosticsContracts.swift`.
- Add the contract to `contracts/app_contract_manifest.json` when it is part of a hot path fuzz oracle.
- Emit it with `DiagnosticsStore.requireContract(_:_:metadata:)` for fail-closed guards or `DiagnosticsStore.recordContractViolation(_:metadata:)` for after-the-fact async failures.

Default app contract categories:

- Identity preconditions before effect installation: contact ID, backend channel, remote user, peer device, and local device identity agree.
- Epoch preconditions before callbacks and async continuations mutate state.
- Ownership preconditions before media, PTT, backend, or relay side effects leave the app.
- Projection postconditions after backend/app state is merged for selected UI and readiness.
- Transport preconditions before accepting Direct QUIC, media relay, websocket ACK, or audio frames.

`DiagnosticsStore.requireContract(...)` records a `DiagnosticsInvariantViolation` and an error diagnostic with `contractName`, `contractKind`, `invariantID`, and `scope` metadata, then returns `false` so callers can fail closed:

```swift
guard diagnostics.requireContract(
    isCurrentAttempt,
    kind: .precondition,
    invariantID: "transmit.stale_startup_side_effect",
    scope: .local,
    subsystem: .pushToTalk,
    message: "stale transmit startup completion rejected",
    metadata: ["channelId": channelID]
) else {
    return
}
```

Use `DiagnosticsStore.recordContractViolation(...)` when the violation is discovered after the fact rather than through a boolean guard. This is appropriate for async callbacks, timeouts, backpressure drops, duplicate completions, missing expectations, and bridge code that receives already-classified `contractKind`/`invariantID` metadata from a lower layer.

Ad hoc calls with raw `kind`, `invariantID`, and `metadata` remain valid for bridge code and one-off detectors. For durable hot paths, use the catalogue so fuzzing, tests, and documentation share the same contract name and evidence fields.

Every new runtime contract should have a focused proof when practical. The test should assert the structured invariant violation and the paired error diagnostic, not just the human-readable log line. See [`TESTING.md`](/Users/mau/Development/bb/TESTING.md) for the contract test pattern.

## Production Visibility

Invariant detection is not only a local-development feature. If the same bug can happen in TestFlight or production, the invariant must be visible or reconstructable from production-capable evidence.

Evidence paths:

- app diagnostics and invariant violations exported by shake-to-report
- iOS telemetry facts and telemetry events with `invariantId`
- Unison/backend telemetry facts and backend invariant events
- backend latest diagnostics snapshots and transcripts
- `just reliability-intake-shake`, `just reliability-intake`, and `just production-replay`

Single-runtime invariants should emit the `invariantId` where they are detected. True distributed invariants usually cannot be proven by one device; each runtime should emit correlated facts, and a later correlator should evaluate the pair/convergence predicate.

Required correlation fields, when available:

- user handle and device ID
- peer handle and peer device ID
- channel/session/attempt/transmit IDs
- selected phase and relationship
- backend readiness, membership, and transmit facts
- timestamps and capture reason

For distributed production invariants, choose one of these designs:

- Move the rule to the backend if the backend owns enough canonical state to prove it live.
- Emit per-device fact events and evaluate the predicate in telemetry, reliability intake, merged diagnostics, or a backend correlation job.
- Make shake-to-report preserve enough peer evidence for an on-demand merge.
- Mark the rule development-only only when production detection is explicitly not required.

## Where Rules Belong

Choose the smallest seam that can prove the rule.

- Put app-local rules in Swift diagnostics when one device can prove the contradiction from typed state or a backend snapshot.
- Put backend-owned rules in Unison when the backend owns the fact, such as canonical readiness, membership, request truth, wake-target selection, or transmitter exclusivity.
- Put pair/convergence rules in merged diagnostics when no single runtime has the whole predicate.

Do not treat a distributed-state bug as fully encoded if every invariant lives only in the UI or merged analyzer while the backend owns the broken fact. Client checks may fail closed, preserve evidence, or trigger safe repair, but they do not replace a backend fix for backend-owned truth.

## Naming And Evidence

Rule IDs must stay stable over time. They tie together diagnostics, telemetry, merged analysis, handoffs, bug reports, and regressions.

Use:

- `<subject>.<claim>`
- short factual names
- the broken truth, not the symptom
- `selected.*` for selected Conversation projection rules
- `pair.*` for merged multi-device rules
- `channel.*`, `backend.*`, or domain-specific prefixes for backend-owned rules

Good:

- `selected.ready_without_join`
- `selected.peer_joined_ui_not_connectable`
- `pair.backend_ready_ui_not_live`

Bad:

- `ui_broken_again`
- `weird-ready-bug`
- `fix-me`

Every emitted violation should include enough context to classify ownership and replay the failure. Prefer expected/observed facts over generic prose.

Good evidence:

- `selectedConversationPhase=ready while isJoined=false`
- `backendSelfJoined=true backendPeerJoined=true backendPeerDeviceConnected=false`
- `channelId=... deviceId=... attemptId=...`

## Encoding Rules

### App

Use `DiagnosticsStore.recordInvariantViolation(...)` for explicit app-side violations. Snapshot invariants may also be derived automatically in `Turbo/AppDiagnostics.swift`.

For state-machine code:

- Check event preconditions before applying events that should be rejected or ignored.
- Check transition postconditions after deriving next state when the reducer owns the fact.
- Check projection invariants where canonical state becomes UI or diagnostics state.

Do not crash production code for recoverable distributed invariant failures. Emit the invariant, fail closed in projection if needed, and use `SELF_HEALING.md` for bounded repair. Reserve debug assertions for programmer-only impossibilities.

```swift
diagnostics.recordInvariantViolation(
    invariantID: "selected.ready_without_join",
    scope: .local,
    message: "selectedConversationPhase=ready while isJoined=false",
    metadata: [
        "selectedConversationPhase": selectedConversationState.phase.rawValue,
        "isJoined": String(isJoined),
        "reason": reason,
    ]
)
```

### Backend

Use `turbo.service.internal.appendInvariantEvent` for backend-owned invariant events.

```unison
_ =
  turbo.service.internal.appendInvariantEvent
    db
    currentUserId
    "backend.ptt_push_target_missing_token"
    "backend"
    "backend"
    "active transmit did not have a token-backed wake target"
    (Some metadata)
    ()
```

Keep backend emitters narrow and authoritative. Emit where the backend can prove the contradiction from its own state.

### Merged Diagnostics

Use `scripts/merged_diagnostics.py` for pair and convergence rules. It:

- parses app and backend invariant events
- merges iOS and backend telemetry
- converts complete telemetry state facts into snapshot facts
- derives pair/convergence violations
- supports `--json` and `--fail-on-violations`

For focused proof on that lane, use [`scripts/test_merged_diagnostics.py`](/Users/mau/Development/bb/tools/scripts/test_merged_diagnostics.py). It is the repo's unit-style regression surface for:

- pair detector predicates
- `currentViolations` versus `historicalViolations` classification
- replay/dashboard consumers of merged diagnostics payloads

When the proof target is downstream artifact preservation rather than live derivation, prefer the checked-in replay fixtures under [`fixtures/production_replay/`](/Users/mau/Development/bb/shared/fixtures/production_replay), especially [`merged_diagnostics_pair_matrix.json`](/Users/mau/Development/bb/shared/fixtures/production_replay/merged_diagnostics_pair_matrix.json) for multiple current pair violations in one payload.

If app/backend runtime already emits an invariant for the same broken truth, keep the merged rule aligned to the same `invariantId`. Use a new `pair.*` or `convergence.*` ID only when the merged view proves a broader contradiction.

## Proof Lanes

An invariant is not done when it only logs. Add the narrowest durable proof that would have failed before the fix.

Use:

- Swift or Unison reducer/property tests for pure transition or projection rules.
- Backend tests or route probes for backend-owned truth.
- TLA+ for protocol semantics, ownership, stale facts, monotonicity, convergence, or all interleavings.
- Seeded fuzzing for duplicate/drop/reorder/retry/reconnect/restart/timing families.
- Simulator scenarios when the concrete app/backend journey adds evidence beyond the smaller proof.
- Physical-device checks only for Apple/PTT/audio/hardware boundaries.

Useful commands:

- `just protocol-model-checks`
- `just simulator-fuzz-local <seed> <count>`
- `just simulator-fuzz-replay <artifact-dir>`
- `just simulator-fuzz-shrink <artifact-dir>`
- `python3 scripts/merged_diagnostics.py --json --fail-on-violations ...`

A scenario is valuable, but not mandatory for every physical-device discovery. If TLA+ plus a reducer/backend test proves the impossible state cannot be reached, and a simulator scenario would only restate the same pure rule slowly, document that decision in the registry or handoff.

## Registry

`invariants/registry.json` is the active catalog. Do not maintain a second hand-written list of current IDs in this file.

When adding or changing invariant IDs, update the registry and run:

```bash
python3 scripts/check_invariant_registry.py
```
