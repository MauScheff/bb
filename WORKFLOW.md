# Workflow Model

Canonical agent model. Use `AGENTS.md` for read routing, `ENGINE.md` for the engine contract, `TOOLING.md` for commands, and `docs/architecture/AGENT_NATIVE_SYSTEM_STRUCTURE.md` for structural design doctrine when changing module boundaries, state machines, workflows, effects, or verification strategy.

## Core Loop

```text
report -> diagnostics -> owner -> invariant/regression -> fix -> prove -> release/check
```

1. Restate the request as the fact that must become true or the fact that was broken.
2. Collect the smallest diagnostics needed to locate ownership.
3. Identify the authoritative owner before editing.
4. Encode impossible behavior as a named invariant or regression.
5. Fix the owning subsystem, not only the visible symptom.
6. Prove the fix with the narrowest useful automated proof.
7. Run the release check or broader gate that matches the blast radius.

Prefer the better long-term design over a quick patch when it removes a class of failures. Refactor aggressively when the current model, contract, or projection is the source of the problem; changing backend models or shared contracts is preferable to adding client compensation that only hides one symptom.

## Reliability Discovery Loop

Use this loop for ongoing reliability work, not only incident response. Fuzzing is the interleaving search engine; invariants are the oracle; replays are the debugging artifact; promoted tests, corpus cases, scenarios, or backend proofs are the durable memory.

```text
invariant -> generated interleavings -> replay/shrink -> owner -> narrow regression -> fix -> gate
```

| Step | Rule | Output |
| --- | --- | --- |
| Name the truth | Start from a stable invariant, precondition, postcondition, liveness rule, or convergence rule. | Existing or new `invariantId`, or an explicit reason the rule is not machine-detectable yet. |
| Generate pressure | Run the cheapest fuzz or scenario lane that can violate that truth. | Seed, count, command, and artifact path. |
| Stop on first failure | Do not continue sweeping past a serious failure. Replay it exactly; shrink simulator failures. | Stable reproduction and minimized scenario when available. |
| Classify owner | Identify whether the broken fact belongs to backend/shared truth, engine, Swift adapter/projection, pair convergence, or Apple/PTT/audio boundary. | Owner and proof lane. |
| Promote downward | Convert the failure into the lowest durable proof that owns the rule. | Kernel corpus case, Rust runtime test, engine corpus/scenario, Swift test, backend proof/probe, or checked-in simulator scenario. |
| Fix the owner | Change the source subsystem, not only the symptom or projection. | Structural fix plus diagnostics/contract evidence when recurrence must be explainable. |
| Gate the blast radius | Rerun the narrow proof, then the smallest broader gate that exercises the changed surface. | Passing proof commands and artifact paths. |

Default commands:

```bash
just reliability-gate-regressions
just beepbeep-backend-gate local 123 3
just reliability-fuzz-self-hosted-overnight 12345 500
just reliability-fuzz-local-overnight 12345 500
```

Escalate only when the lower lane cannot represent the failure. Device testing is a boundary confirmation step for Apple/PTT/audio/hardware behavior, not the normal discovery mechanism.

## Ownership

Classify before editing.

| Owner | Scope | Fix location |
| --- | --- | --- |
| Backend/shared truth | identity, devices, direct Conversation records, Beeps/Beep Threads, membership, readiness, wake targeting, runtime signaling, active Talk Turn ownership | Unison/backend or shared contract |
| Client projection/reducer | local derivation, selected Conversation projection, UI state, coordinator transitions, app-local idempotence | Swift state machines, coordinators, typed projections |
| Pair/convergence rule | contradictions requiring two device perspectives or device plus backend evidence | merged diagnostics detector, backend truth when backend has enough state |
| Apple/PTT/audio adapter | PushToTalk UI, microphone permission, backgrounding, lock-screen wake, audio-session activation, real capture/playback | adapter/device boundary after shared logic is proven below it |

Do not patch backend-owned contradictions only in Swift. Client changes may add guardrails, diagnostics, fail-closed projection, or safer recovery, but they do not replace the backend or contract fix.

## Boundary Classification

Every simulator, physical-device, TestFlight, production, or shake-report failure must be classified before fixing:

| Classification | Meaning | Required proof path |
| --- | --- | --- |
| Crosses engine boundary | The failure can be represented as engine intents, events, effects, clock deadlines, backend facts, media chunks, Connection changes, Talk Turn lifecycle facts, or Device/PTT facts. | Extract or construct an engine replay/scenario/fuzz case first; fix the owning reducer/adapter; promote the case to `TurboEngine` tests or fixtures when stable. |
| App adapter/effect executor | The engine model is correct, but app-side execution of Apple PTT, AVAudio, backend client, Fast Relay, Direct QUIC, timers, or projection glue is wrong. | Add a focused Swift test around the adapter/effect executor; feed modeled facts back into the engine when possible. |
| Distributed integration | The failure requires two app instances, real backend route semantics, runtime-control timing, merged diagnostics, or scenario DSL actions. | Use live-local engine proof first when route semantics are enough; otherwise use simulator scenarios or strict merged diagnostics. |
| Apple/PTT/audio boundary | The remaining unknown is real PushToTalk UI, microphone permission, audio-session activation, lock-screen/background wake, hardware capture, or hardware playback. | Keep exact physical evidence; add modeled engine or Swift adapter failure coverage when possible; retest only the failed device cell after lower lanes are green. |

Do not label a bug device-only merely because it was found on devices. If the event sequence crosses the engine boundary, replay or model it headlessly before changing production logic. If it is truly Apple/PTT/audio-only, document the unreplayable boundary and still prove app fail-closed behavior with the closest engine or Swift adapter model.

For current app builds, shake/manual diagnostics uploads are expected to carry `engineTrace` inside structured diagnostics. For any production, simulator, or physical-device report that crosses the engine boundary, try `just engine-trace-extract` and `just engine-trace-replay` before inventing a new scenario. If a fresh report lacks `engineTrace`, classify that as a diagnostics export/intake regression unless the build predates trace upload; then reconstruct the smallest engine scenario from the available facts.

For live-audio gaps, prove the media rule before another device loop: classify the lane capability, reproduce packet loss/reorder/duplicate or ordered backlog in `TurboEngine`, add/adjust the app boundary proof that executes the same sequence/drop policy, then use physical devices only for the remaining Apple/PTT/audio/hardware boundary.

Current lane classification is part of the proof. `direct-quic` and `media-relay-packet` are unordered packet media; `media-relay-tcp` is the ordered reliable media fallback. Runtime/backend control is not a live media lane. Backend `audio-chunk` signals are a `media.runtime_never_carries_live_audio` violation and must be rejected, not played. Do not treat a lane as unordered because the engine can model it; the app adapter must emit typed evidence from the actual transport boundary. If a packet lane cannot establish packet media, fail that lane and let transport selection fall back to an explicitly named degraded Fast Relay lane instead of sending audio over a hidden stream-media compatibility path.

Packet media liveness is also part of lane proof. Direct QUIC and Fast Relay QUIC datagram audio sends are best-effort and must not wait for ordered/reliable completion callbacks; control, signaling, and ordered fallback media may remain reliable/ordered. A live-audio stall with green engine replay belongs first to the app media adapter proof lane.

## Modeling Rules

Think algebraically before patching. Model workflows as explicit state machines:

```text
State + Event -> NewState + Commands
```

- Use ADTs/sum types for mutually exclusive modes.
- Put state-specific data inside the matching variant.
- Encode ownership, phases, permissions, readiness, and capabilities in domain types where practical, so illegal combinations are unrepresentable.
- Store canonical truth once and derive projections from it.
- Normalize UI gestures, backend updates, runtime-control notices, timers, and Apple callbacks into typed events.
- Prefer monotonic state structures for distributed facts; use explicit invalidation, tombstones, epochs, or leases when facts must move backward.
- Keep side effects in adapters, clients, coordinators, or command runners.
- Make retries, duplicates, reconnects, refreshes, and stale completions idempotent or convergent.
- Prefer operations with clear algebraic laws: idempotent retries, commutative merges where ordering is unreliable, associative accumulation for evidence, and deterministic joins for projections.
- Treat durable facts and runtime facts differently; runtime facts often need leases, epochs, fencing, tombstones, or explicit invalidation.
- Fail closed when a capability cannot be proven.

Avoid boolean bundles, string status values, UI latches, duplicated projections, and precedence rules that hide distributed states. If the model is wrong, redesign the model before adding conditionals.

For nontrivial structural work, use [`AGENT_NATIVE_SYSTEM_STRUCTURE.md`](/Users/mau/Development/bb/docs/architecture/AGENT_NATIVE_SYSTEM_STRUCTURE.md) as the doctrine: vertical semantic modules, ADTs for shape, state machines for time, explicit effect capabilities for reality, algebraic laws for composition, and generated verification for trust.

## Invariants

Use [`INVARIANTS.md`](/Users/mau/Development/bb/docs/reliability/INVARIANTS.md) for ID naming, registry rules, and emission APIs.

- `shared/invariants/registry.json` is the central index for invariant identity, owner, detector, evidence, repair policy, and proof status.
- Put executable checks at the narrowest seam that has typed context: Swift reducer/projection, Unison route/service/projection, merged diagnostics, TLA+, or fuzz oracle.
- When relevant, prove the algebraic law directly: idempotence, monotonicity, commutativity, convergence, or illegal-state unrepresentability.
- Production-capable failures must be visible or reconstructable from production-capable evidence.
- Emit expected/observed machine-readable facts, not only prose.
- For recoverable invalid states, pair the invariant with [`SELF_HEALING.md`](/Users/mau/Development/bb/docs/reliability/SELF_HEALING.md): bounded, idempotent repair plus diagnostics and proof that nearby valid in-flight states do not repair.

Useful report shape:

```text
observer -> subject -> initial conditions -> event sequence -> expected invariant -> observed violation
```

After diagnostics, build a contradiction ledger: broken preconditions, postconditions, invariants, and liveness expectations. Each item must end in one state:

- reused an existing `invariantId` with a focused proof
- registered a new `invariantId` with detection and a focused proof
- explicitly deferred because the predicate is Apple/hardware-only, not yet machine-detectable, or needs more evidence

One green regression is insufficient when the run exposed multiple broken contracts. Encode or explicitly defer each important contradiction.

When the owning code depends on a critical assumption that can be checked at runtime, add a diagnostic contract at the earliest seam where the predicate is knowable. Prefer `DiagnosticsStore.requireContract(...)` for guard-style preconditions and `DiagnosticsStore.recordContractViolation(...)` for already-observed failures, timeouts, drops, and duplicate completions. Contract annotations are part of the fix when they make future production evidence explain which assumption stopped holding.

## Proof Order

Use the narrowest proof that exercises the owner and failure mode.

| Order | Lane | Claim |
| --- | --- | --- |
| 1 | TurboEngine tests/headless scenarios | Conversation, Connection, Talk Turn, PTT, media, and low-level transport rules in the algebraic core |
| 2 | Swift reducer/domain/property tests | pure app rules, projection logic, app-local convergence, fixed boundary mappings |
| 3 | Unison/backend tests or route probes | backend-owned truth, routes, stores, projections |
| 4 | TLA+ | protocol semantics, ownership, stale facts, ordering, retries, duplicate/drop/reorder, leases, all interleavings |
| 5 | Simulator scenarios | distributed app/backend journeys that need app target, scenario DSL, or merged diagnostics |
| 6 | Strict merged diagnostics | pair/convergence evidence and scenario artifact validation |
| 7 | Seeded fuzzing | generated interleavings, reconnect, retry, restart, refresh, timing perturbations |
| 8 | Physical devices | Apple PushToTalk UI, microphone permission, backgrounding, lock-screen wake, audio-session activation, real capture/playback |

Do not add slow scenario coverage when a lower-level proof or TLA+ model proves the impossible state better.

Practical command ladder:

```bash
just engine-test
just engine-scenario <scenario>
just serve-local
just engine-scenario-local <scenario>
just engine-fuzz-local <seed> <count>
just swift-test-target <name>
just simulator-scenario <scenario>
just reliability-fuzz-local-overnight <seed> <count>
just reliability-gate-regressions
just device-run <device>
just device-test <device>
```

Stop climbing when the current proof exercises the owner and the failure mode. Continue upward only when the next layer adds a boundary that the lower layer cannot model.

## Engine-First Devflow

- Model phases, evidence, typed reasons, and effects in `TurboEngine` before app coordination.
- Use `just engine-test` and `just engine-scenario <name>` for reducer, synthetic media, PTT timing, Conversation lifecycle, Connection fallback, and low-level transport behavior.
- Use `just serve-local` plus `just engine-scenario-local <name>` or `just engine-fuzz-local <seed> <count>` for backend semantics without simulator startup.
- Keep `PTTViewModel`, SwiftUI, Apple PTT, AVAudio, Fast Relay, Direct QUIC, and backend clients as effect executors or typed event adapters.
- Escalate by boundary: Swift tests for app projections/adapters, simulator scenarios for distributed app/backend journeys, physical devices for real Apple/PTT/audio behavior.
- Promote field evidence downward into the smallest replayable proof lane.
- Record command, scenario/seed, invariant ID, and artifact path in final notes, handoffs, and regressions.

## Common Task Lanes

Use `AGENTS.md` for read routing. Use `fuzz.md` for the fuzz operator loop. Common lanes: engine core, Swift/app rule, backend route/storage/deploy, mixed app/backend bug, distributed scenario, fuzz failure, protocol/interleaving question, telemetry/shake report, recoverable invalid state.

## Definition Of Done

A nontrivial fix is done when:

- ownership is explicit
- the source subsystem is fixed
- the important invariant or regression is named
- diagnostics preserve the evidence needed to debug recurrence
- the narrow proof passes
- the broader gate matches the blast radius
- backend changes are deployed when live behavior depends on them
- device-only claims are clearly separated from automated proof
