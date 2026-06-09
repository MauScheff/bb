# State-Machine Testing

Status: active workflow guide.
Canonical home for: scenario-worthiness and proof boundaries for distributed app/backend behavior.
Related docs: [`ENGINE.md`](/Users/mau/Development/bb/ENGINE.md) owns headless engine scenarios and the engine architecture contract; [`scenarios/README.md`](/Users/mau/Development/bb/README.md) owns scenario catalog, DSL, commands, generated inputs, probes, and diagnostics details; [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md) owns the global ownership/invariant/proof model.

Do not start with manual device tap-through debugging when a state-machine proof can express the behavior. Do not start with the iOS simulator when a `TurboEngine` package test or headless scenario can express it.

## Proof Boundary

| Lane | Use for |
| --- | --- |
| `just engine-test` | reducer, invariant, effect emission, impossible-state tests |
| `just engine-scenario <name>` | synthetic audio, mocked PTT, lifecycle, virtual network faults, transport fallback without backend |
| `just engine-scenario-local <name>` / `just engine-fuzz-local <seed> <count>` | same headless engine against `turbo.serveLocal` route semantics |
| `just simulator-scenario <name>` | iOS app target, app adapters/effect executors, backend route/projection integration, simulator PushToTalk shim, merged diagnostics |

If a physical-device report can be reduced to one of the first three lanes, prove it there before asking for another device run.

## Scenario Loop

1. Restate the bug as a violated invariant or broken projection.
2. Encode the smallest useful story as a checked-in deterministic scenario.
3. Reproduce it against the local or hosted control plane.
4. Inspect merged diagnostics and typed state projections.
5. Fix the owning reducer, coordinator, backend route, or backend projection seam.
6. Keep the scenario as a regression when it adds evidence beyond lower-level proof.

## When To Add A Scenario

Add a checked-in scenario when the bug depends on a distributed app/backend journey:

- multiple actors
- explicit action order
- backend routes or runtime-control notices
- simulator PushToTalk callbacks
- deterministic waits, delays, duplicates, drops, reordering, or forced refreshes
- selected Conversation, contact-list, backend-readiness, or diagnostics expectations

Do not add a slow scenario when a lower-level reducer, domain, backend, or TLA+ proof captures the whole invariant better.

Each new reproducible distributed bug should usually leave behind:

- one end-to-end scenario when the journey matters
- at least one lower-level reducer, projection, backend, or property test for the broken rule underneath it
- a named invariant or regression that explains the class of failure

`scenarios/README.md` owns JSON format, catalog, commands, fault actions, invariant expectations, generated inputs, fuzz lane, production replay conversion, probes, local backend loop, and diagnostics rules.

## Report Shape

Report format:

```text
observer -> subject -> initial conditions -> event sequence -> expected invariant -> observed violation
```

For physical reports, preserve taps only when they matter. Convert the report into the smallest shared-state event story.

## Assertion Targets

Prefer typed projections over labels.

| Surface | Assert |
| --- | --- |
| selected Conversation | phase, status, join state |
| contact list | state per handle |
| backend channel | readiness as seen by app |
| backend audio/wake | audio readiness, wake readiness |
| engine/app effects | emitted or forbidden effects |
| convergence | state after retries, reordering, duplicate signals |

The same machine-readable projection should feed scenario assertions and diagnostics snapshots. `APP_STATE.md` owns backend contract details for Beep Thread relationship, membership, summary status, conversation status, readiness, audio readiness, and wake readiness.

## Apple Boundary

If the bug reproduces in simulator or local backend, fix the shared state-machine path. If it reproduces only on physical devices after simulator scenarios and route probes are green, classify it as Apple/device adapter conformance.

For foreground audio smoke verification, the current known-good boundary contract is:

- both devices converge to `ready`
- local hold-to-talk remains disabled while that device is still `Preparing audio...`
- local hold-to-talk remains disabled until backend `audioReadiness.peer.kind == ready`
- `wakeReady` appears only when backend `wakeReadiness.peer.kind == wake-capable`
- first press plays the Apple start beep and reaches `transmitting` quickly
- the receiver reaches `receiving` and hears audio on that first press
- release returns both sides to `ready`

Background/lock-screen wake proof split:

| Layer | Proves |
| --- | --- |
| backend/probe | wake-capable targeting, incoming push delivery |
| Swift tests | local wake-activation state machine, fallback rules |
| physical devices | incoming push, `PTT audio session activated`, lock-screen playback |

Expected wake-failure classification:

- no wake target
- no push sent
- no incoming push received
- incoming push received but no system activation
- system activation succeeded but playback still failed

## References

- [`SIMULATOR_FUZZING.md`](/Users/mau/Development/bb/docs/reliability/SIMULATOR_FUZZING.md): generated interleavings, artifact layout, replay, shrinking, and promotion from fuzz failure to checked-in regression.
- [`TLA_PLUS.md`](/Users/mau/Development/bb/docs/reliability/TLA_PLUS.md): protocol-level invariant discovery for stale projections, dropped/duplicated/reordered signals, reconnects, lease expiry, wake targeting, and ownership of shared truth.
- [`PRODUCTION_TELEMETRY.md`](/Users/mau/Development/bb/docs/reliability/PRODUCTION_TELEMETRY.md): telemetry, shake reports, reliability intake, and production evidence.
- [`TOOLING.md`](/Users/mau/Development/bb/TOOLING.md): exact commands for scenarios, probes, gates, production replay, and hosted verification.

## Diagnostics Authority

Scenario runs and normal app debug runs both use the diagnostics backend but have different authority:

- normal debug builds may auto-publish diagnostics after high-signal state transitions
- simulator scenarios publish explicit scenario-tagged diagnostics artifacts at the end of the run
- simulator scenario view models disable automatic diagnostics publishing so the explicit scenario artifact remains authoritative for exact-device verification

When diagnosing a scenario failure, trust the scenario artifact and merged scenario diagnostics first. Treat ad hoc debug uploads as supporting material, not as the proof source.
