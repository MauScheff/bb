# How To Fuzz

Purpose: run repeatable Turbo fuzz sweeps, stop on the first real failure, and promote every stable failure into the lowest durable proof lane.

Authority: this file is the operator runbook. Detailed simulator generator mechanics live in [`SIMULATOR_FUZZING.md`](/Users/mau/Development/bb/docs/reliability/SIMULATOR_FUZZING.md). General proof ordering lives in [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md).

## Rules

- Start at the lowest lane that can express the invariant.
- Use local backend fuzz for volume; use hosted and physical devices only for boundaries that local tooling cannot prove.
- Do not keep fuzzing past the first serious failure. Replay, shrink, classify, fix, and promote it before searching for the next bug.
- Do not leave a useful failure as only a seed. Convert it to a package test, engine scenario, Swift test, backend proof, or checked-in simulator scenario.
- Save exact seed, count, artifact path, failing command, invariant IDs, and replay command in final notes or handoffs.

## Lanes

| Lane | Command | Owner | First artifact | Done condition |
| --- | --- | --- | --- | --- |
| Engine package regression | `just engine-test` | `TurboEngine` reducer/domain rules | SwiftPM test output | Package tests pass. |
| Engine fuzz corpus | `just engine-fuzz-corpus` | Promoted engine fuzz regressions | `Packages/TurboEngine/Fixtures/fuzz-corpus.json` | Every checked-in fuzz case passes. |
| PTT readiness adapter fuzz | `just ptt-readiness-fuzz` | Single-agent app adapter/effect readiness contracts | Swift Testing failure output | Generated adapter evidence satisfies PTT readiness contracts or the first failure is promoted. |
| Audio packet fuzz | `just audio-packet-fuzz` | App media packet, transport envelope, scheduler timing, wake activation, device-derived incident corpus and mutations, and synthetic playout boundary | Swift Testing failure output | Packet gate, transport loopback, scheduler late-IO/cushion drain, wake activation buffering, checked-in incident replay/mutation, and synthetic playout properties pass or the first failure is promoted. |
| Live-local engine fuzz | `just engine-fuzz-local <seed> <count>` | Engine rules with `turbo.serveLocal` route semantics | `/tmp/turbo-engine-fuzz/` | All reports pass or the first failure is promoted. |
| Simulator fuzz smoke | `just simulator-fuzz-local <seed> <count>` | App/backend scenario DSL, view model, merged diagnostics | `/tmp/turbo-scenario-fuzz/` | All seeds pass strict diagnostics and engine trace replay. |
| Overnight local reliability fuzz | `just reliability-fuzz-local-overnight <seed> <count>` | Broad local engine plus simulator coverage | `/tmp/turbo-engine-fuzz/`, `/tmp/turbo-scenario-fuzz/` | First failure is fixed/promoted, or all seeds pass. |
| Physical/device matrix | `RELIABILITY_PLAN.md` cells | Apple/PTT/audio/hardware only | reliability intake artifact | Lower lanes are green and the physical boundary passes. |

## Daily Workflow

Start local backend:

```bash
just serve-local
```

Run the cheap baseline:

```bash
just reliability-gate-regressions
```

Run the main local bug-finding sweep:

```bash
just reliability-fuzz-local-overnight 12345 500
```

Use a different seed after a clean run when you want broader search:

```bash
just reliability-fuzz-local-overnight 8675309 500
```

For a quick smoke after changing fuzz machinery:

```bash
just serve-local
just ptt-readiness-fuzz
just audio-packet-fuzz
just engine-fuzz-local 123 3
just simulator-fuzz-local 123 1
```

Convert a device or shake report into an audio corpus before asking for another physical retest:

```bash
just reliability-intake @mau @bau
just audio-incident-replay /tmp/turbo-reliability-intake/<run>/audio-incident-corpus.json
just audio-incident-mutate /tmp/turbo-reliability-intake/<run>/audio-incident-corpus.json
```

Reliability intake generates `audio-incident-corpus.json` automatically when merged diagnostics contain replayable audio facts. Use the lower-level converter directly only when working from a custom merged diagnostics artifact:

```bash
just audio-incident-corpus /tmp/turbo-debug/<run>/merged-diagnostics.json /tmp/turbo-debug/<run>/audio-incident-corpus.json <name>
just audio-incident-replay /tmp/turbo-debug/<run>/audio-incident-corpus.json
just audio-incident-mutate /tmp/turbo-debug/<run>/audio-incident-corpus.json
```

## Failure Loop

1. Stop on the first failure.
2. Identify the artifact path printed by the command.
3. Replay the exact failure.
4. Shrink simulator failures.
5. Classify ownership.
6. Add the narrowest failing proof.
7. Fix the owning subsystem.
8. Rerun the narrow proof, then `just reliability-gate-regressions`.
9. Resume the original fuzz command to find the next independent failure.

Replay simulator fuzz:

```bash
just simulator-fuzz-replay /tmp/turbo-scenario-fuzz/<run-id>/seed-<seed>
```

Shrink simulator fuzz:

```bash
just simulator-fuzz-shrink /tmp/turbo-scenario-fuzz/<run-id>/seed-<seed>
```

Replay engine fuzz:

```bash
just engine-scenario 'fuzz_case:<seed>:<index>'
```

Replay an engine trace extracted from simulator diagnostics:

```bash
just engine-trace-replay /tmp/turbo-scenario-fuzz/<run-id>/seed-<seed>/engine-trace.json
```

## Promotion Rules

| Failure owner | Promote to | Proof command |
| --- | --- | --- |
| Engine reducer/domain rule | `Packages/TurboEngine/Tests` package test | `just engine-test` |
| Engine interleaving family | `Packages/TurboEngine/Fixtures/fuzz-corpus.json` or named engine scenario | `just engine-fuzz-corpus` |
| Engine trace from app/device evidence | Engine package test, scenario, or corpus case | `just engine-trace-replay <trace>` first |
| App audio packet/playout evidence from diagnostics | Audio incident corpus plus state mutations | `just audio-incident-corpus <merged-diagnostics> <corpus> <name>`, then `just audio-incident-replay <corpus>` and `just audio-incident-mutate <corpus>` |
| App adapter/effect executor | Focused `TurboTests` Swift test | `just swift-test-target <name>` |
| App/backend distributed journey | Checked-in `scenarios/*.json` plus `scenarios/README.md` entry | `just simulator-scenario-local <name>` |
| Backend truth/route contract | Unison/backend proof or route probe | Use `UNISON.md` and `TOOLING.md` |
| Apple/PTT/audio/hardware boundary | Physical matrix retest only after lower proofs are green | `RELIABILITY_PLAN.md` |

## Simulator Artifact Checklist

Each simulator fuzz seed directory should contain:

- `scenario.json`
- `metadata.json`
- `result.json`
- `reproduce.sh`
- `xcode-output.txt`
- `merged-diagnostics.txt`
- `merged-diagnostics.json`
- `merged-diagnostics-strict.txt`
- `engine-trace.json`
- `engine-trace-extract.txt`
- `engine-trace-replay.txt`
- `minimized.json` after successful shrink

`result.json` must show zero exit codes for scenario execution, strict diagnostics, engine trace extraction, and engine trace replay before a seed is considered green.

## Contract Oracles

Runtime contracts are fuzz oracles. A seed is not green if it emits a `DiagnosticsInvariantViolation` for a non-allowed contract, even when the visible scenario completes.

For new app hot-path assumptions:

1. Reuse or add the invariant ID in `invariants/registry.json`.
2. Add a `DiagnosticsContracts` factory in `Turbo/DiagnosticsContracts.swift`.
3. Add the contract to `contracts/app_contract_manifest.json`.
4. Assert `contractName`, `contractKind`, `invariantID`, `scope`, and correlation metadata in a focused Swift test.
5. Let simulator fuzz strict diagnostics fail on the emitted violation.

Use contracts for logical assumptions that can break under stale backend state, reordered effects, timing races, duplicate callbacks, or missing expectations. Use regular diagnostics for informational breadcrumbs that should not fail fuzzing.

Prefer contracts at these boundaries:

- Identity: contact, backend channel, remote user, peer device, and local device must agree before installing effects.
- Epoch: async completions, timers, ACKs, and side effects must still belong to the current request/transmit/receive epoch.
- Ownership: outgoing media, PTT callbacks, and backend writes must have a single current owner.
- Projection: backend inactive/absent states must clear local live/readiness projections unless a named grace rule applies.
- Receiver readiness: `receiver-ready` must come from stable receiver evidence, must not publish while a leave or reconciled teardown is in flight, and equivalent readiness publishes are allowed only once per control-plane epoch unless a named reconnect recovery boundary exists.
- Stale backend/timing faults: delayed channel refreshes, stale peer-device state, duplicated readiness/presence delivery, and backend `not found` during teardown must fail closed, converge pending actions, or emit a named stale-state invariant.
- Transport: relay, Direct QUIC, and media-relay frames must match the current channel and peer binding before mutating state.

## Escalation

Escalate only when the lower lane cannot represent the failure:

- Engine fuzz to Swift test when the app adapter or effect executor matters.
- Swift test to simulator scenario when two app instances, backend routes, websocket timing, or merged diagnostics matter.
- Simulator scenario to physical devices only for Apple PushToTalk UI, microphone permission, background/lock-screen wake, audio-session activation, real capture, or real playback.

Do not classify a fuzz-found or device-found failure as Apple/PTT/audio-only until engine replay/modeling and Swift adapter proof are inapplicable or already green.
