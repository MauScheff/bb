# Turbo

Archived reference. This file describes the old `/Users/mau/Development/Turbo`
shape and staging-era commands. Active BeepBeep work uses
[`/Users/mau/Development/bb/README.md`](/Users/mau/Development/bb/README.md),
[`/Users/mau/Development/bb/TOOLING.md`](/Users/mau/Development/bb/TOOLING.md),
and the production API base URL `https://api.beepbeep.to`.

Turbo is an iOS Push-to-Talk app backed by the BeepBeep control plane.

The app owns Apple PushToTalk, audio, local projection, and user interaction surfaces. The active backend owns shared control-plane truth through a Rust runtime plus a pure Unison kernel: identity, devices, direct channels, Beeps, membership, readiness, wake targeting, runtime signaling, and Talk Turn ownership.

The backend is the control plane, not the media plane.

Active backend work lives under [`/Users/mau/Development/bb/backend`](/Users/mau/Development/bb/backend). The canonical deployed base URL is `https://api.beepbeep.to`.

## For Humans

If you are reporting a bug, give the agent:

- reporter handle
- Friend handle, if there was one
- incident ID, if shake-to-report produced one
- what each side did
- what should have happened
- what actually happened
- whether this was debug, TestFlight, production-like, simulator, or physical device

Good prompt:

```text
I reproduced a device issue. The handles were @a and @b.
I used shake-to-report. The incidentId was <id>.
Expected: ...
Actual: ...
Please run reliability intake, classify ownership, convert this into an invariant
or regression where possible, fix the owning seam, and prove the fix.
```

## Agent Entry

Agents start from [`AGENTS.md`](/Users/mau/Development/Turbo/AGENTS.md).

The canonical agent thinking model is [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md):

```text
report -> diagnostics -> owner -> invariant/regression -> fix -> prove -> release/check
```

Use [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) for exact commands and operational details.

## Primary Commands

| Need | Command |
| --- | --- |
| Run engine package tests | `just engine-test` |
| Run one headless engine scenario | `just engine-scenario foreground_transmit_receive` |
| Run one engine scenario against local backend | `just engine-scenario-local foreground_transmit_receive` |
| Fuzz engine scenarios against local backend | `just engine-fuzz-local 12345 500` |
| Intake a two-device report | `just reliability-intake @mau @bau` |
| Intake a shake report | `just reliability-intake-shake @mau <incidentId> @bau` |
| Run one simulator scenario | `just simulator-scenario <name>` |
| Run local overnight reliability fuzz | `just reliability-fuzz-local-overnight 12345 500` |
| Inspect strict simulator diagnostics | `just simulator-scenario-merge-strict` |
| Fast regression gate | `just reliability-gate-regressions` |
| Hosted smoke gate | `just reliability-gate-smoke` |
| Full hosted scenario gate | `just reliability-gate-full` |
| Local full scenario gate | `just reliability-gate-local` |
| Protocol model checks | `just protocol-model-checks` |
| Verify an existing deploy | `just postdeploy-check` |
| Run the BeepBeep backend reliability gate | `just beepbeep-backend-gate` |
| Run the hosted BeepBeep backend gate | `just beepbeep-backend-production-gate` |
| Check BeepBeep backend cutover readiness | `just beepbeep-backend-cutover-readiness` |
| Production preflight, deploy, and verify | `just deploy-production` |
| Production preflight | `just production-preflight` |
| Production deploy and verify | `just deploy-production` |

## Default Proof Ladder

Use the cheapest proof that can exercise the behavior:

1. `just engine-test` for Foundation-only call/session/PTT/media/transport reducer rules.
2. `just engine-scenario <name>` for synthetic audio, virtual PTT, lifecycle, and transport interleavings that do not need a backend.
3. `just serve-local`, then `just engine-scenario-local <name>` or `just engine-fuzz-local <seed> <count>` when the same engine story should run against a local backend.
4. `just swift-test-target <name>` or `just swift-test-suite` when the app-side projection, adapter, or effect executor is part of the claim.
5. `just simulator-scenario <name>` or a reliability gate when the journey needs the iOS app target, backend routes, scenario DSL, or merged diagnostics.
6. Physical devices only for Apple PushToTalk UI, microphone permission, background/lock-screen wake, audio-session activation, and real capture/playback.

## Local Development

Use `just` for repeated workflows.

Backend entrypoints:

- `just beepbeep-backend-gate`: local Rust runtime plus Unison kernel reliability gate
- `just beepbeep-backend-production-gate`: production backend reliability gate against `https://api.beepbeep.to`
- `just beepbeep-backend-cutover-readiness`: machine-readable readiness report for the canonical backend lane
- `just serve-local-http`: local HTTP route checks
- `just serve-local`: local websocket-capable backend for simulator scenarios
- `just engine-scenario-local <scenario>`: headless engine scenario against `http://localhost:8090/s/turbo`
- `just engine-fuzz-local <seed> <count>`: replayable live-local engine fuzzing against `http://localhost:8090/s/turbo`
- `just deploy-production`: strict production deploy plus hosted verification
- `just production-preflight`: strict local proof gate before production
- `just deploy-production`: strict production deploy plus hosted verification
- `just postdeploy-check`: hosted verification after a deploy

Set `TurboBackendBaseURL` in [`Turbo/Info.plist`](/Users/mau/Development/Turbo/Turbo/Info.plist) to the backend you are exercising:

- `http://localhost:8081/s/turbo` for local HTTP route checks
- `http://localhost:8090/s/turbo` for local websocket-backed simulator scenario work
- `http://<mac-lan-ip>:8081/s/turbo` for physical device against local HTTP
- `https://api.beepbeep.to` for the deployed backend

If local UI behavior looks impossible, restart the local backend and clear runtime state before drawing conclusions.

## Source Of Truth

- Swift app code: [`Turbo/`](/Users/mau/Development/Turbo/Turbo)
- Swift tests: [`TurboTests/`](/Users/mau/Development/Turbo/TurboTests)
- engine package: [`Packages/TurboEngine`](/Users/mau/Development/Turbo/Packages/TurboEngine)
- Unison backend code: local Unison codebase `turbo/main`, accessed through MCP/UCM
- scenarios: [`scenarios/`](/Users/mau/Development/Turbo/scenarios)
- invariant registry: [`invariants/registry.json`](/Users/mau/Development/Turbo/invariants/registry.json)
- operational commands: [`justfile`](/Users/mau/Development/Turbo/justfile)
- diagnostics and proof scripts: [`scripts/`](/Users/mau/Development/Turbo/scripts)
- TLA+ specs: [`specs/tla/`](/Users/mau/Development/Turbo/specs/tla)

Repo-root `.u` files are scratch/workflow artifacts, not the backend source of truth.

## Docs Map

Read only what the task needs:

- [`AGENTS.md`](/Users/mau/Development/Turbo/AGENTS.md): agent entrypoint and doc routing
- [`Beep-Beep-Product-Thesis.md`](/Users/mau/Development/Turbo/Beep-Beep-Product-Thesis.md): latest product, brand, and marketing thesis
- [`PRODUCT_BRIEF.md`](/Users/mau/Development/Turbo/PRODUCT_BRIEF.md): implementation-facing product reference
- [`BRAND.md`](/Users/mau/Development/Turbo/BRAND.md): product copy, positioning, tone, and UI direction
- [`INVESTOR_BRIEF.md`](/Users/mau/Development/Turbo/INVESTOR_BRIEF.md): investor positioning reference
- [`DEMO_NARRATIVE.md`](/Users/mau/Development/Turbo/DEMO_NARRATIVE.md): demo and marketing narrative script
- [`ENGINE_HUMANS.md`](/Users/mau/Development/Turbo/ENGINE_HUMANS.md): agent-facing plain-language explanation of Turbo Engine
- [`ENGINE.md`](/Users/mau/Development/Turbo/ENGINE.md): technical contract for TurboEngine architecture, state, adapters, simulation, and proof
- [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md): canonical agent thinking model
- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md): command selection and operational workflows
- [`TESTING.md`](/Users/mau/Development/Turbo/TESTING.md): Swift Testing selector and proof rules
- [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md): app architecture and Swift-side working rules
- [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md): simulator, device, PTT, and audio debugging
- [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md): Unison workflow and backend editing rules
- [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md): Unison syntax and semantics
- [`beepbeep/backend/README.md`](/Users/mau/Development/Turbo/beepbeep/backend/README.md): active BeepBeep backend entrypoint
- [`beepbeep/backend/docs/ARCHITECTURE.md`](/Users/mau/Development/Turbo/beepbeep/backend/docs/ARCHITECTURE.md): active Rust runtime plus Unison kernel architecture
- [`UNISON_KERNEL_RUST_RUNTIME.md`](/Users/mau/Development/Turbo/UNISON_KERNEL_RUST_RUNTIME.md): historical plan retained for context
- [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md): backend/storage/query/deploy guidance
- [`BACKEND_STRUCTURE.md`](/Users/mau/Development/Turbo/BACKEND_STRUCTURE.md): quick backend namespace map
- [`MIGRATIONS.md`](/Users/mau/Development/Turbo/MIGRATIONS.md): Unison Cloud storage schema changes
- [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md): invariant naming, placement, diagnostics, and regressions
- [`SELF_HEALING.md`](/Users/mau/Development/Turbo/SELF_HEALING.md): bounded repair for recoverable invalid states
- [`RELIABILITY_PLAN.md`](/Users/mau/Development/Turbo/RELIABILITY_PLAN.md): strategic reliability architecture and workstreams
- [`RELIABILITY_GUIDELINES.md`](/Users/mau/Development/Turbo/RELIABILITY_GUIDELINES.md): reliability review questions and companion guidance
- [`RELIABILITY_CHECKLIST.md`](/Users/mau/Development/Turbo/RELIABILITY_CHECKLIST.md): design, debugging, proof, and release checklists
- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md): deterministic scenario workflow
- [`TLA_PLUS.md`](/Users/mau/Development/Turbo/TLA_PLUS.md): protocol model checking
- [`fuzz.md`](/Users/mau/Development/Turbo/fuzz.md): fuzz operator runbook
- [`SIMULATOR_FUZZING.md`](/Users/mau/Development/Turbo/SIMULATOR_FUZZING.md): seeded distributed scenario fuzzing mechanics
- [`PRODUCTION_TELEMETRY.md`](/Users/mau/Development/Turbo/PRODUCTION_TELEMETRY.md): telemetry setup, alerts, and shake reports
- [`handoffs/README.md`](/Users/mau/Development/Turbo/handoffs/README.md): active session handoff conventions
- [`journal/README.md`](/Users/mau/Development/Turbo/journal/README.md): durable design/debugging notes

## Current Work State

Current blockers and active work state live in [`handoffs/`](/Users/mau/Development/Turbo/handoffs). Do not treat old handoffs as current truth without checking newer evidence.
