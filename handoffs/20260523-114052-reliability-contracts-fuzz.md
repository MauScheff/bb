# Handoff 2026-05-23 11:40

## Summary

Reliability contract work is implemented and locally proven. The app now has clearer boundaries between Apple/local PTT session evidence, TurboEngine joined-session evidence, backend membership projection, and transmit/media side effects. The immediate next work is not another local fix; it is a longer fuzz sweep, simulator-fuzz artifact retention cleanup, then the physical-device matrix for Apple/PTT/audio-only surfaces.

## Current truth

- `just swift-test-suite` passed with 1,295 tests executed.
- `just reliability-gate-regressions` passed.
- `just engine-fuzz-local 123 3` passed.
- `just simulator-fuzz-local 123 1` passed after clearing generated `/tmp` artifacts.
- `just simulator-scenario-local foreground-ptt` passed.
- `just simulator-scenario-merge-local-strict` passed with no current or historical invariant violations.
- `python3 scripts/check_invariant_registry.py` passed: 125 registered, 125 active, 86 referenced.
- `python3 -m json.tool contracts/app_contract_manifest.json >/dev/null` passed.
- `git diff --check` passed.
- Local backend on `http://localhost:8090/s/turbo` was stopped after the proof run.

## What changed this session

- Split local Apple/PTT evidence from engine/backend evidence:
  - `localSessionEvidenceExists` remains Apple/system-local only.
  - `localOrEngineSessionEvidenceExists` allows TurboEngine joined evidence where backend/session preservation needs it.
  - Backend engine session evidence no longer counts as Apple local session evidence.
- Updated backend/session preservation call sites to use the correct evidence boundary.
- Fixed Apple-gated transmit startup behavior:
  - Direct QUIC receiver transmit prepare no longer blocks Apple system transmit handoff.
  - Warm Direct QUIC capture is explicitly deferred until Apple audio activation.
  - Background transition media suspension avoids interrupting active engine transmit lifecycles.
- Made `appleGatedWarmDirectQuicDefersCaptureUntilAppleAudioActivation` wait on actual transmit/capture milestones instead of fixed sleeps.
- The broader dirty worktree also includes the reliability-contract framework and docs from the active plan:
  - invariant registry and app contract manifest updates
  - `DiagnosticsContracts.swift`
  - `fuzz.md`
  - simulator fuzz and merged-diagnostics tooling updates
  - reliability workflow docs

## What is not working

- No product correctness failure is currently known from the latest local proof run.
- Simulator fuzz initially failed before app launch because `/tmp/turbo-scenario-fuzz` had only 3.4 GiB free and the runner requires 4.0 GiB.
- Direct QUIC production identity provisioning still reports missing simulator entitlement in simulator logs. This is expected for simulator proof lanes and is not a pass/fail signal for physical Direct QUIC identity behavior.
- Physical Apple/PTT/audio surfaces are not proven by the local simulator lanes:
  - real PushToTalk UI
  - lock-screen wake
  - microphone permission
  - audio-session activation on device
  - actual capture/playback path

## Recommended next step

1. Add simulator-fuzz artifact retention or auto-clean for generated `/tmp/turbo-scenario-fuzz` and `/tmp/turbo-dd-simulator-scenario` data.
2. Run a longer overnight local sweep with `just reliability-fuzz-local-overnight <seed> <count>`.
3. Run the physical-device reliability matrix one cell at a time. Stop on first serious failure, shake both devices, run reliability intake, then promote the failure into the narrowest automated proof before continuing.

## Commands that matter

```bash
# Cheap health checks
python3 scripts/check_invariant_registry.py
python3 -m json.tool contracts/app_contract_manifest.json >/dev/null
git diff --check

# Core proof lanes already green
just swift-test-suite
just reliability-gate-regressions

# Local backend and fuzz/scenario lanes
just serve-local
just engine-fuzz-local 123 3
just simulator-fuzz-local 123 1
just simulator-scenario-local foreground-ptt
just simulator-scenario-merge-local-strict

# Recommended next long run
just reliability-fuzz-local-overnight <seed> <count>

# If a physical or simulator run fails
mkdir -p /tmp/turbo-debug
just reliability-intake @mau @bau
just engine-trace-extract /tmp/turbo-debug/<run>/merged-diagnostics.txt /tmp/turbo-engine-trace.json
just engine-trace-replay /tmp/turbo-engine-trace.json
```

## Files that matter

- [AGENTS.md](/Users/mau/Development/Turbo/AGENTS.md)
- [WORKFLOW.md](/Users/mau/Development/Turbo/WORKFLOW.md)
- [INVARIANTS.md](/Users/mau/Development/Turbo/INVARIANTS.md)
- [fuzz.md](/Users/mau/Development/Turbo/fuzz.md)
- [SIMULATOR_FUZZING.md](/Users/mau/Development/Turbo/SIMULATOR_FUZZING.md)
- [TESTING.md](/Users/mau/Development/Turbo/TESTING.md)
- [TOOLING.md](/Users/mau/Development/Turbo/TOOLING.md)
- [DiagnosticsContracts.swift](/Users/mau/Development/Turbo/Turbo/DiagnosticsContracts.swift)
- [app_contract_manifest.json](/Users/mau/Development/Turbo/contracts/app_contract_manifest.json)
- [registry.json](/Users/mau/Development/Turbo/invariants/registry.json)
- [PTTViewModel+Selection.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+Selection.swift)
- [PTTViewModel+BackendSync.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+BackendSync.swift)
- [PTTViewModel+BackendLifecycle.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+BackendLifecycle.swift)
- [PTTViewModel+Transmit.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+Transmit.swift)
- [TurboTests.swift](/Users/mau/Development/Turbo/TurboTests/TurboTests.swift)
- [run_simulator_fuzz.py](/Users/mau/Development/Turbo/scripts/run_simulator_fuzz.py)
- [merged_diagnostics.py](/Users/mau/Development/Turbo/scripts/merged_diagnostics.py)

## Artifacts

- Swift suite result: `/tmp/turbo-swift-test-suite.xcresult`
- Engine fuzz local result: `/tmp/turbo-engine-fuzz/seed-123-56422359-81ad-4ae4-ab64-547b2a9e2e70/result.json`
- Simulator fuzz local artifacts: `/tmp/turbo-scenario-fuzz/20260523-111711-c55ed428`
- Simulator scenario derived data and logs: `/tmp/turbo-dd-simulator-scenario`
- Trace extraction smoke artifact: `/tmp/turbo-engine-trace-smoke-extracted.json`
- Synthetic probe smoke artifact: `/tmp/turbo-synthetic-conversation-probe-smoke`
- SLO dashboard smoke artifact: `/tmp/turbo-slo-dashboard-smoke`

## Notes

- Do not classify future physical-device failures as Apple/PTT/audio-only until engine trace replay and Swift/app-backend proof lanes are inapplicable or already green.
- Treat backend/shared truth as backend-owned unless evidence proves an app projection or adapter bug.
- For every new failure, name or reuse an invariant before fixing.
- The worktree is intentionally dirty with reliability docs, tooling, app code, tests, and new contract files. Do not revert unrelated dirty files.
