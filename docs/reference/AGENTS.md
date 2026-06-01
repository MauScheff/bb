# Purpose

This is the agent entrypoint for Turbo. Read this first, then load only the files needed for the task.

Humans mostly use [`README.md`](/Users/mau/Development/Turbo/README.md). All other checked-in `.md` files are agent-facing operational docs unless they explicitly say otherwise.

# Repo Facts

- Turbo is an iOS Push-to-Talk app backed by the Beep Beep Rust runtime plus a pure Unison kernel.
- Swift app code lives in [`Turbo/`](/Users/mau/Development/Turbo/Turbo); Swift tests live in [`TurboTests/`](/Users/mau/Development/Turbo/TurboTests).
- Engine core code lives in [`Packages/TurboEngine`](/Users/mau/Development/Turbo/Packages/TurboEngine); the architecture contract is [`ENGINE.md`](/Users/mau/Development/Turbo/ENGINE.md).
- Canonical product/domain terminology lives in [`GLOSSARY.md`](/Users/mau/Development/Turbo/GLOSSARY.md); use it before introducing or renaming domain concepts.
- Latest product, brand, and marketing thesis lives in [`Beep-Beep-Product-Thesis.md`](/Users/mau/Development/Turbo/Beep-Beep-Product-Thesis.md).
- Backend source of truth is [`beepbeep/backend`](/Users/mau/Development/Turbo/beepbeep/backend): Rust runtime/effects plus Unison kernel definitions under `beepbeep.*` in the local `turbo/main` Unison codebase.
- The canonical hosted backend base URL is `https://staging.beepbeep.to`.
- The previous Unison Cloud backend and repo-root `.u` scratch files are archived under [`archive/unison-cloud`](/Users/mau/Development/Turbo/archive/unison-cloud) for reference only.
- Repeated operational flows should go through [`justfile`](/Users/mau/Development/Turbo/justfile) recipes when available.
- The invariant registry is [`invariants/registry.json`](/Users/mau/Development/Turbo/invariants/registry.json); app hot-path runtime contract annotations are catalogued in [`contracts/app_contract_manifest.json`](/Users/mau/Development/Turbo/contracts/app_contract_manifest.json) and emitted through [`Turbo/DiagnosticsContracts.swift`](/Users/mau/Development/Turbo/Turbo/DiagnosticsContracts.swift).

# Default Workflow

Use [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md) as the canonical thinking model:

```text
report -> diagnostics -> owner -> invariant/regression -> fix -> prove -> release/check
```

Default rules:

- Start from the smallest authoritative docs and source needed for the task.
- Classify ownership before editing distributed, shared-state, backend-contract, or selected-conversation projection bugs.
- Fix the source subsystem, not just the visible client symptom.
- Prefer the long-term design fix when it removes a class of failures, even if that means refactoring backend models, contracts, or client projections more aggressively than a local patch.
- Think algebraically before patching: choose domain types, monotonic transitions, idempotent operations, and convergence rules that make invalid states unrepresentable or self-resolving.
- Treat backend/shared truth as backend-owned unless proven otherwise.
- Convert impossible behavior into a named invariant or regression.
- Prove with the narrowest useful automated proof before broader gates.
- Classify every simulator, physical-device, production, or shake-report failure as `crosses engine boundary`, `app adapter/effect executor`, `distributed integration`, or `Apple/PTT/audio boundary` before choosing a fix.
- If a failure crosses the engine boundary, extract/replay `engineTrace` first; model it with `TurboEngine` only when trace is unavailable or insufficient.
- Ask for physical-device verification only for Apple/PTT/audio/hardware surfaces that cannot be exercised from repo tooling.

# Agent Fast Path

Use this decision table before choosing tools:

| Task shape | First proof lane | Escalate only when |
| --- | --- | --- |
| Call/session/PTT/media/transport rule expressible without iOS frameworks | `just engine-test` or `just engine-scenario <name>` | Backend route semantics, app adapters, or platform behavior matter |
| Same engine rule with production-like backend semantics | `just beepbeep-backend-gate` or `just self-hosted-scenario-fuzz-local <seed> <count>` | The iOS app target, websocket scenario DSL, or merged diagnostics must be exercised |
| App projection or effect-executor behavior | `just swift-test-target <name>` | The claim depends on two app instances, backend routes, or scenario timing |
| Distributed app/backend journey | `just simulator-scenario <name>` or a reliability gate | The remaining unknown is Apple/PTT/audio hardware behavior |
| Broad backend reliability sweep | `just reliability-fuzz-self-hosted-overnight <seed> <count>` | A failure needs shrinking, promotion, or physical Apple/PTT/audio validation |
| Physical-device or shake report | `just reliability-intake...`, then convert shared failures into lower-level proofs; use `just device-run` / `just device-test` only for the remaining hardware cell | The failure is confirmed to be Apple/PTT/audio/permission/background only |

Default escalation rule:

1. Start at the lowest lane that can represent the invariant.
2. Stop climbing once that lane exercises the owner and failure mode.
3. Promote failures downward when possible: physical report -> engine trace replay -> Swift/backend proof -> simulator/local replay when distribution is essential.
4. Keep artifacts replayable: save fuzz seeds, scenario names, intake paths, invariant IDs, and exact commands.

Do not start with the simulator or physical phones for engine-owned logic. Do not mark a report Apple/PTT/audio-only until engine replay/modeling and Swift adapter proof are inapplicable or already green. Do not add UI flags or duplicate source-of-truth projections to compensate for a missing engine/backend state.

# Read Routing

Load the smallest row that covers the task.

| Task | Required docs | Rules |
| --- | --- | --- |
| Swift/iOS/UI | `SWIFT.md`, `TESTING.md`; add `ENGINE.md` for call/session/PTT/media/transport or `PTTViewModel` authority; add `SWIFT_DEBUGGING.md` for simulator, PushToTalk, device, or audio debugging | Use `just swift-test-target <name>` for targeted Swift `@Test` proofs. Raw `xcodebuild -only-testing` is not proof unless it runs a nonzero Swift Testing test. |
| Engine core | `ENGINE.md`, `SWIFT.md`, `TESTING.md` | `TurboEngine` owns local call/session/PTT/media/transport truth. Core imports only `Foundation`; reducers emit typed effects; old-shaped booleans exist only as derived fixed-boundary outputs. |
| Backend/routes/storage/deploy | `beepbeep/backend/README.md`, `beepbeep/backend/docs/ARCHITECTURE.md`, `TOOLING.md`; add `UNISON_LANGUAGE.md` for kernel syntax and `TLA_PLUS.md` for live-control ownership or reconnect protocol changes | Rust owns effects and storage; Unison owns pure kernel decisions under `beepbeep.*`; prove with `just beepbeep-backend-gate` before trusting staging. |
| Archived Unison Cloud backend archaeology | `archive/unison-cloud/README.md`, `UNISON.md`, `BACKEND.md`, `BACKEND_STRUCTURE.md` | Reference only. Do not put new active backend behavior on the old `turbo.*` Cloud path unless explicitly asked. |
| Mixed app/backend bug | `WORKFLOW.md`, `TOOLING.md`, `ENGINE.md`, `SWIFT.md`, `SWIFT_DEBUGGING.md`, `beepbeep/backend/docs/ARCHITECTURE.md` | Inspect backend projection/route ownership and client projection before fixing. A frontend-only patch is incomplete when backend truth is wrong. |
| Invariants/diagnostics/reliability | `WORKFLOW.md`, `INVARIANTS.md`; add `SELF_HEALING.md` for repair, `STATE_MACHINE_TESTING.md` for scenario proofs, `PRODUCTION_TELEMETRY.md` for telemetry/shake intake, `RELIABILITY_PLAN.md` for active reliability sprint work | Name the invariant, choose the narrowest detector, keep production-capable evidence machine-readable. |
| Scenario/fuzz/protocol | `fuzz.md`, `STATE_MACHINE_TESTING.md`, `SIMULATOR_FUZZING.md`, `TLA_PLUS.md`, `scenarios/README.md` | Prefer engine tests/headless scenarios first. Escalate to simulator when app/backend integration or merged diagnostics are required. |
| Semantic refactor/terminology | `GLOSSARY.md`, `WORKFLOW.md`; add the smallest owner docs for the touched area | Start with an 80/20 concept map when the target is broad. Refactor one concept at a time, update glossary/rename ledger before code renames, and prove semantic equivalence through the narrowest proof lane. |
| Product/copy/brand | `Beep-Beep-Product-Thesis.md`, `GLOSSARY.md`, `PRODUCT_BRIEF.md`, `BRAND.md` | Treat the thesis as the latest product/brand/marketing source, then use glossary terms and narrower product/brand docs for implementation-facing precision. Keep product-facing text in `README.md` or explicit product docs; other `.md` files are agent-facing. |

# Handoffs And Journal

- Use [`handoffs/`](/Users/mau/Development/Turbo/handoffs) for active work state. If asked to write a handoff, create a new timestamped file from [`handoffs/TEMPLATE.md`](/Users/mau/Development/Turbo/handoffs/TEMPLATE.md).
- Use [`journal/`](/Users/mau/Development/Turbo/journal) for durable design/debugging lessons. If asked to write a journal entry, create a new timestamped file from [`journal/TEMPLATE.md`](/Users/mau/Development/Turbo/journal/TEMPLATE.md).
- When starting fresh on an existing thread of work, read [`handoffs/README.md`](/Users/mau/Development/Turbo/handoffs/README.md) and the latest relevant handoff. Do not treat old handoffs as current truth without checking newer evidence.

# Agent Doc Style

Except for [`README.md`](/Users/mau/Development/Turbo/README.md), markdown docs should optimize for agents executing work:

- Prefer command tables, decision tables, ownership rules, proof ladders, and exact file paths over narrative.
- When adding or changing a workflow, update the routing docs in the same change: `AGENTS.md` for what to read, `WORKFLOW.md` for the proof model, `TOOLING.md` for commands, and `TESTING.md` for proof rules.
- Every workflow doc should answer: owner, first proof lane, escalation condition, artifact path, and done condition.
- Keep human/product explanation in `README.md` or clearly label it as agent orientation for explaining context.
- Avoid stale transitional language. Describe the current architecture, not migration intent, unless historical context is needed to interpret old artifacts.

# Repo Defaults

- Prefer structural fixes over tactical patches that increase coupling.
- Do not avoid refactors when the model is wrong: changing the backend model or shared contract is better than preserving a brittle shape and compensating in the client.
- Prefer type-level and model-level prevention over runtime compensation: encode ownership, phases, permissions, and readiness in domain types where practical.
- Prefer existing repo interfaces before inventing bespoke flows: `just`, Unison MCP/UCM, Xcode/simulator tooling, and checked-in scripts.
- Treat observability, verification, and repeatable debug loops as part of implementation.
- Treat documentation and testing as part of the definition of done for core Unison/backend work.
- Keep backend scope control-plane-only unless the user explicitly changes it.
- Use automated simulator scenarios and probes before physical-device debugging when the bug is not obviously Apple/PTT/audio-specific.
