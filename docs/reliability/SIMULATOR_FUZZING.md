# Simulator Fuzzing

Related docs: [`ENGINE.md`](/Users/mau/Development/bb/ENGINE.md) owns headless engine fuzzing and simulation for TurboEngine; [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/bb/docs/reliability/STATE_MACHINE_TESTING.md) owns simulator scenario proof boundaries.

Simulator fuzzing generates deterministic, model-based scenario JSON from integer seeds, runs it through `SimulatorScenarioTests`, and writes replayable artifacts under `/tmp`.

Use it for distributed control-plane/state-machine bugs involving app intents, backend refreshes, runtime-control faults, HTTP delays, restart/reconnect, and simulator PushToTalk shim behavior. It does not prove real Apple PushToTalk UI, microphone permission, lock-screen wake, or actual device audio.

Prefer headless engine fuzzing for engine-local session/transmit/receive/media ordering/transport/lifecycle/deadline behavior. Use simulator fuzz only when the interleaving must exercise the app target, backend scenario DSL, runtime-control fault injection, merged diagnostics, or simulator PushToTalk shim.

Headless engine entrypoints:

```sh
just engine-test
just engine-scenario foreground_transmit_receive
just self-hosted-up
just self-hosted-serve 127.0.0.1:8091
just engine-scenario-local foreground_transmit_receive http://127.0.0.1:8091/s/turbo
just engine-fuzz-local 12345 500 http://127.0.0.1:8091/s/turbo
```

Engine fuzz artifacts are written under `/tmp/turbo-engine-fuzz/`. Use those first when the failure can be replayed without the iOS simulator.

## Entry Points

```sh
just self-hosted-up
just self-hosted-serve 127.0.0.1:8091
just simulator-fuzz-local 123 3 http://127.0.0.1:8091/s/turbo
just simulator-fuzz-local-overnight 12345 500 http://127.0.0.1:8091/s/turbo
just reliability-fuzz-local-overnight 12345 500 http://127.0.0.1:8091/s/turbo
just simulator-fuzz-replay /tmp/turbo-scenario-fuzz/<run-id>/seed-<seed>
just simulator-fuzz-shrink /tmp/turbo-scenario-fuzz/<run-id>/seed-<seed>
```

Default active runtime URL: `http://127.0.0.1:8091/s/turbo`. Local fuzz assumes `just self-hosted-up` and `just self-hosted-serve` are running.

For end-to-end reliability sweeps that should cover the new engine first, use
`just reliability-fuzz-local-overnight <seed> <count>`. It runs
`engine-fuzz-local` before the simulator overnight lane, so engine-local media,
transport, lifecycle, and PTT timing regressions fail in the cheaper headless
lane before XCTest starts.

## Components

| Component | Responsibility |
| --- | --- |
| `scripts/run_simulator_fuzz.py` | seed expansion, generation, artifacts, replay, shrink |
| `scripts/run_simulator_scenarios.py` | runtime config, simulator lane lock, transient XCTest retry |
| `TurboTests/SimulatorScenarioTests` | checked-in scenarios plus generated `scenarioFile` / `scenarioDirectory` inputs |
| `scripts/merged_diagnostics.py` | exact-device diagnostics merge and strict invariant failure |
| `TurboTests` property helpers | deterministic Swift property harness for pure invariants |

There is no SwiftCheck dependency. Swift property tests use `PropertyRunConfig`,
`SeededRNG`, and failure messages that include seed, iteration, generated input
summary, expected invariant, and observed state.

## Generated Scenario Flow

Each seed creates one two-actor scenario:

- `a`: `@avery`, device id `sim-fuzz-<seed>-avery`
- `b`: `@blake`, device id `sim-fuzz-<seed>-blake`

The generator is model-based, not random tapping. Default journey:

1. both Friends open each other
2. sender sends a Beep
3. recipient accepts and joins
4. sender completes the join
5. optional runtime-control reconnect or app restart perturbation
6. one Friend transmits
7. that Friend ends transmit
8. optional background / foreground perturbation
9. one Friend disconnects

Controlled noise:

- refreshes for contact summaries, Beeps, and channel state
- delayed and repeated action delivery
- HTTP delays on typed routes
- runtime-control signal delay, drop, duplicate, and reorder faults
- redundant commands and stale refreshes
- asynchronous channel refreshes that can complete after transmit-stop or disconnect, exercising stale backend snapshot handling
- app restart, runtime-control reconnect, background, and foreground events where the
  simulator scenario DSL supports them

Generated scenarios use the same JSON DSL as checked-in scenarios and run through `scenarioFile`.

## Oracle

A fuzz seed fails when either oracle fails:

- the simulator scenario XCTest run exits non-zero
- strict merged diagnostics exits non-zero because invariant violations were
  published by the app/backend diagnostics path
- scenario diagnostics do not contain an extractable, replayable `TurboEngine`
  trace

Failures may come from scenario expectations or diagnostics-backed invariants. Important distributed contradictions should have typed invariant IDs, not only timeouts or label mismatches.

Fuzz diagnostics are collected with local telemetry disabled, so local TLS or
Cloudflare telemetry availability does not decide the result.

## Artifact Layout

Each run creates:

```text
/tmp/turbo-scenario-fuzz/<run-id>/
  run-metadata.json
  seed-<seed>/
    scenario.json
    metadata.json
    result.json
    reproduce.sh
    xcode-output.txt
    merged-diagnostics.txt
    merged-diagnostics.json
    merged-diagnostics-strict.txt
    engine-trace.json
    engine-trace-extract.txt
    engine-trace-replay.txt
    minimized.json                 # present after a successful shrink
    minimized-xcode-output.txt      # present after a successful shrink
    shrink-result.json              # present after shrink
    shrink-candidates/
      candidate-0001/
        scenario.json
        metadata.json
        result.json
        xcode-output.txt
        merged-diagnostics.txt
        merged-diagnostics.json
        merged-diagnostics-strict.txt
        engine-trace.json
        engine-trace-extract.txt
        engine-trace-replay.txt
```

| File | Use |
| --- | --- |
| `scenario.json` | generated scenario |
| `metadata.json` | seed, name, base URL, actors, devices, replay command |
| `result.json` | scenario exit, strict diagnostics exit, failed flag |
| `xcode-output.txt` | full simulator test output |
| `merged-diagnostics.txt` | readable exact-device diagnostics |
| `merged-diagnostics.json` | machine-readable diagnostics |
| `merged-diagnostics-strict.txt` | strict invariant pass/fail output |
| `engine-trace.json` | extracted `TurboEngine` trace from merged diagnostics |
| `engine-trace-extract.txt` | extraction output; nonzero exit fails the seed |
| `engine-trace-replay.txt` | `TurboEngine` replay output; nonzero exit fails the seed |
| `minimized.json` | preferred repro after shrink |
| `reproduce.sh` | exact replay command |

Artifacts stay outside the repo. Fuzz never promotes failures into `scenarios/` automatically.

## Replay

Replay uses `minimized.json` when present, otherwise `scenario.json`. Confirm stability before investigation or promotion:

```sh
just simulator-fuzz-replay /tmp/turbo-scenario-fuzz/<run-id>/seed-<seed>
```

Replay rewrites output and diagnostics files in the artifact directory.

## Shrinking

The shrinker preserves the same oracle: a candidate must fail the scenario run or strict diagnostics.

Shrink passes are deliberately conservative:

- remove whole steps only when the step has no `expectEventually` assertion and
  contains no core journey action
- remove individual actions only when they are not core journey actions
- simplify fault parameters: action delays `0`, repeat counts `1`, repeat intervals `0`, HTTP/runtime-control delays `0`, fault counts `1`; reorder faults keep `count = 2`

Core journey actions are preserved during removal:

- `openFriend`
- `connect`
- `beginTransmit`
- `endTransmit`
- `backgroundApp`
- `foregroundApp`
- `disconnect`
- `restartApp`

Invalid candidates are rejected, including missing selected Conversation before `refreshChannelState`, removed actor setup, or unknown actions.

The shrinker is a v1 reducer, not a full delta-debugging engine. It is useful
when it removes obvious noise and leaves a shorter valid repro. It is acceptable
to stop a long shrink once it has produced a useful `minimized.json`.

## Scenario File And Directory Inputs

`SimulatorScenarioTests` runs `scenarios/*.json` by default.

Generated inputs use runtime config: `scenarioFile` for one JSON file, `scenarioDirectory` for every `*.json` in a generated directory.

The Python wrapper exposes these as:

```sh
python3 scripts/run_simulator_scenarios.py \
  --scenario-file /tmp/example/scenario.json \
  --scenario fuzz_seed_123 \
  --base-url http://127.0.0.1:8091/s/turbo
```

Use this path for generated/temporary scenarios. Promote only stable, readable regressions into `scenarios/`.

## Failure To Regression

When fuzzing finds a failure:

1. Replay the artifact.
2. Shrink it.
3. Inspect `minimized.json` if present, otherwise `scenario.json`.
4. Read `xcode-output.txt` for the scenario step and assertion failure.
5. Read `merged-diagnostics.txt` and `merged-diagnostics.json` for invariant
   IDs, selected Conversation projection, backend readiness, audio readiness, wake
   readiness, and pair convergence evidence.
6. Identify the authoritative owner of the broken fact.
7. Add or strengthen the invariant if the oracle did not name the broken truth.
8. Fix the source subsystem, not just the visible projection.
9. Promote the minimized scenario into `scenarios/` only after it is stable and
   useful as a regression.
10. Add a lower-level Swift or Unison property regression for the pure rule that
    should prevent recurrence.

Promotion requires a descriptive checked-in scenario and an entry in `scenarios/README.md`. Keep seed artifacts as debug evidence, not source-controlled tests.

## Focused Property Tests

Simulator fuzz is expensive: XCTest, simulator, local backend, merged diagnostics. Keep pure invariants covered underneath it.

Useful Swift property targets:

```sh
just ptt-readiness-fuzz
just swift-test-target conversationProjectionProperties
just swift-test-target transportFaultPlannerProperties
```

`ptt-readiness-fuzz` checks single-agent adapter evidence around backend readiness,
Apple/PTT session state, transmit startup, remote stop/drain, reconnect grace,
local media readiness, and Direct QUIC path evidence before simulator fuzz.

`conversationProjectionProperties` checks ADT-heavy pure derivations around:

- `ConversationStateMachine.selectedConversationState`
- `ConversationStateMachine.projection`
- `ConversationStateMachine.reconciliationAction`
- projection/detail phase alignment
- selected-contact gating for reconciliation effects
- duplicate reconciled teardown suppression

`transportFaultPlannerProperties` checks scenario transport-planning helpers:

- dropped actions are not scheduled
- repeated actions produce the expected scheduled count
- scheduled actions are monotonic by delivery time
- HTTP delay faults are consumed exactly `count` times
- runtime-control drop faults are consumed exactly `count` times

Backend/domain invariants belong in Unison pure tests when truth belongs to backend ADTs or app/backend contracts. Avoid effectful store fuzzing here unless needed; local simulator fuzz already exercises route/store behavior through the real local service.

## Smoke Checklist

Use this after changing the fuzz machinery:

1. Run the Swift property smoke:

   ```sh
   just swift-test-target conversationProjectionProperties
   just swift-test-target transportFaultPlannerProperties
   ```

2. Run one generated scenario file through the generated input path:

   ```sh
   just self-hosted-up
   just self-hosted-serve 127.0.0.1:8091
   python3 scripts/run_simulator_fuzz.py run --seed 123 --count 1 --base-url http://127.0.0.1:8091/s/turbo
   just simulator-fuzz-replay /tmp/turbo-scenario-fuzz/<run-id>/seed-123
   ```

3. Run one generated scenario directory through `scenarioDirectory` if that path
   changed.

4. Verify checked-in scenarios still use the default path:

   ```sh
   just simulator-scenario-suite-local
   ```

5. For a failure-path proof, replay and shrink a known failing artifact, then
   verify `minimized.json`, `shrink-result.json`, and diagnostics artifacts were
   produced.

Stop the local backend when the smoke is finished.

## Limitations

- Generated scenarios are intentionally two-Friend scenarios today.
- Shrinking is conservative and may leave redundant but valid actions.
- The simulator can prove control-plane readiness and projection behavior, but
  not real audio or Apple UI boundary behavior.
- A fuzz failure is not automatically a regression test. It becomes one only
  after an agent or human minimizes, names, reviews, fixes, and promotes it.
