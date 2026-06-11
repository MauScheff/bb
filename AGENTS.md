# Purpose

This is the agent entrypoint for Turbo. Read this first, then load only the files needed for the task.

Humans mostly use [`README.md`](/Users/mau/Development/bb/README.md). All other checked-in `.md` files are agent-facing operational docs unless they explicitly say otherwise.

# Repo Facts

- BeepBeep is an iOS Push-to-Talk app backed by the BeepBeep Rust runtime plus a pure Unison kernel.
- Swift app code lives in [`client/ios/Turbo/`](/Users/mau/Development/bb/client/ios/Turbo); Swift tests live in [`client/ios/TurboTests/`](/Users/mau/Development/bb/client/ios/TurboTests).
- Engine core code lives in [`client/ios/Packages/TurboEngine`](/Users/mau/Development/bb/client/ios/Packages/TurboEngine); the architecture contract is [`ENGINE.md`](/Users/mau/Development/bb/docs/client/ENGINE.md).
- Canonical product/domain terminology lives in [`GLOSSARY.md`](/Users/mau/Development/bb/GLOSSARY.md); use it before introducing or renaming domain concepts.
- Latest product, brand, and marketing thesis lives in [`Beep-Beep-Product-Thesis.md`](/Users/mau/Development/bb/docs/product/Beep-Beep-Product-Thesis.md).
- Backend source of truth is [`backend`](/Users/mau/Development/bb/backend): Rust runtime/effects plus Unison kernel definitions under `beepbeep.*` in the local `bb/main` Unison codebase.
- Canonical hosted production endpoints are `https://api.beepbeep.to` for the API/control plane and `relay.beepbeep.to:443` for media relay.
- The previous Turbo checkout at `/Users/mau/Development/Turbo` is the recovery archive. Do not route active work there unless explicitly doing archaeology.
- Repeated operational flows should go through [`justfile`](/Users/mau/Development/bb/justfile) recipes when available.
- The invariant registry is [`shared/invariants/registry.json`](/Users/mau/Development/bb/shared/invariants/registry.json); app hot-path runtime contract annotations are catalogued in [`shared/contracts/app_contract_manifest.json`](/Users/mau/Development/bb/shared/contracts/app_contract_manifest.json) and emitted through [`client/ios/Turbo/DiagnosticsContracts.swift`](/Users/mau/Development/bb/client/ios/Turbo/DiagnosticsContracts.swift).
- Agent-native structure doctrine lives in [`docs/architecture/AGENT_NATIVE_SYSTEM_STRUCTURE.md`](/Users/mau/Development/bb/docs/architecture/AGENT_NATIVE_SYSTEM_STRUCTURE.md). Use it for new modules, structural refactors, state-machine/workflow design, effect boundaries, and verification design; do not load it for every small task.

# Default Workflow

Use [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md) as the canonical thinking model:

```text
report -> diagnostics -> owner -> invariant/regression -> fix -> prove -> release/check
```

Use the reliability discovery loop for ongoing bug finding and hardening:

```text
invariant -> generated interleavings -> replay/shrink -> owner -> narrow regression -> fix -> gate
```

Default rules:

- Start from the smallest authoritative docs and source needed for the task.
- Classify ownership before editing distributed, shared-state, backend-contract, or selected-conversation projection bugs.
- Fix the source subsystem, not just the visible client symptom.
- Prefer the long-term design fix when it removes a class of failures, even if that means refactoring backend models, contracts, or client projections more aggressively than a local patch.
- Think algebraically before patching: choose domain types, monotonic transitions, idempotent operations, and convergence rules that make invalid states unrepresentable or self-resolving.
- Treat backend/shared truth as backend-owned unless proven otherwise.
- Convert impossible behavior into a named invariant or regression.
- Treat fuzzing as a search mode, not a proof by itself; promote useful failures into the lowest durable proof lane.
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
| Swift/iOS/UI | `docs/client/SWIFT.md`, `TESTING.md`; add `docs/client/ENGINE.md` for call/session/PTT/media/transport or `PTTViewModel` authority; add `docs/client/SWIFT_DEBUGGING.md` for simulator, PushToTalk, device, or audio debugging | Use `just swift-test-target <name>` for targeted Swift `@Test` proofs. Raw `xcodebuild -only-testing` is not proof unless it runs a nonzero Swift Testing test. |
| Engine core | `docs/client/ENGINE.md`, `docs/client/SWIFT.md`, `TESTING.md` | `TurboEngine` owns local call/session/PTT/media/transport truth. Core imports only `Foundation`; reducers emit typed effects; old-shaped booleans exist only as derived fixed-boundary outputs. |
| Backend/routes/storage/deploy | `backend/README.md`, `backend/docs/ARCHITECTURE.md`, `TOOLING.md`; add `UNISON_LANGUAGE.md` for kernel syntax and `TLA_PLUS.md` for live-control ownership or reconnect protocol changes | Rust owns effects and storage; Unison owns pure kernel decisions under `beepbeep.*`; prove with `just beepbeep-backend-gate` before trusting production. |
| Archived Unison Cloud backend archaeology | `/Users/mau/Development/Turbo`, `docs/reference/` | Reference only. Do not put new active backend behavior on the old `turbo.*` Cloud path unless explicitly asked. |
| Mixed app/backend bug | `WORKFLOW.md`, `TOOLING.md`, `docs/client/ENGINE.md`, `docs/client/SWIFT.md`, `docs/client/SWIFT_DEBUGGING.md`, `backend/docs/ARCHITECTURE.md` | Inspect backend projection/route ownership and client projection before fixing. A frontend-only patch is incomplete when backend truth is wrong. |
| Invariants/diagnostics/reliability | `WORKFLOW.md`, `docs/reliability/INVARIANTS.md`; add `docs/reliability/fuzz.md` for the reliability discovery loop, `docs/reliability/SELF_HEALING.md` for repair, `docs/reliability/STATE_MACHINE_TESTING.md` for scenario proofs, `docs/reliability/PRODUCTION_TELEMETRY.md` for telemetry/shake intake, `docs/reliability/RELIABILITY_PLAN.md` for active reliability sprint work | Name the invariant, choose the narrowest detector, keep production-capable evidence machine-readable, and promote fuzz failures into durable proof. |
| Scenario/fuzz/protocol | `WORKFLOW.md`, `docs/reliability/fuzz.md`, `docs/reliability/STATE_MACHINE_TESTING.md`, `docs/reliability/SIMULATOR_FUZZING.md`, `docs/reliability/TLA_PLUS.md`, `shared/scenarios/README.md` | Prefer engine tests/headless scenarios first. Escalate to simulator when app/backend integration or merged diagnostics are required. Stop on first serious fuzz failure, replay/shrink, classify, promote, then resume. |
| Architecture/module structure | `docs/architecture/AGENT_NATIVE_SYSTEM_STRUCTURE.md`, `WORKFLOW.md`; add the smallest owner docs for the touched area | Use typed domain state, explicit commands/events/reducers, effect capabilities, algebraic laws, manifests/contracts, and generated verification. Keep the doc as doctrine; do not paste it into task context. |
| Semantic refactor/terminology | `GLOSSARY.md`, `WORKFLOW.md`; add the smallest owner docs for the touched area | Start with an 80/20 concept map when the target is broad. Refactor one concept at a time, update glossary/rename ledger before code renames, and prove semantic equivalence through the narrowest proof lane. |
| Product/copy/brand | `docs/product/Beep-Beep-Product-Thesis.md`, `GLOSSARY.md`, `docs/product/PRODUCT_BRIEF.md`, `docs/product/BRAND.md` | Treat the thesis as the latest product/brand/marketing source, then use glossary terms and narrower product/brand docs for implementation-facing precision. Keep product-facing text in `README.md` or explicit product docs; other `.md` files are agent-facing. |

# Handoffs And Journal

- Use [`handoffs/`](/Users/mau/Development/bb/handoffs) for active work state. If asked to write a handoff, create a new timestamped file from [`handoffs/TEMPLATE.md`](/Users/mau/Development/bb/handoffs/TEMPLATE.md).
- Use [`journal/`](/Users/mau/Development/bb/journal) for durable design/debugging lessons. If asked to write a journal entry, create a new timestamped file from [`journal/TEMPLATE.md`](/Users/mau/Development/bb/journal/TEMPLATE.md).
- When starting fresh on an existing thread of work, read [`handoffs/README.md`](/Users/mau/Development/bb/handoffs/README.md) and the latest relevant handoff. Do not treat old handoffs as current truth without checking newer evidence.

# Agent Doc Style

Except for [`README.md`](/Users/mau/Development/bb/README.md), markdown docs should optimize for agents executing work:

- Prefer command tables, decision tables, ownership rules, proof ladders, and exact file paths over narrative.
- When adding or changing a workflow, update the routing docs in the same change: `AGENTS.md` for what to read, `WORKFLOW.md` for the proof model, `TOOLING.md` for commands, and `TESTING.md` for proof rules.
- Every workflow doc should answer: owner, first proof lane, escalation condition, artifact path, and done condition.
- Keep human/product explanation in `README.md` or clearly label it as agent orientation for explaining context.
- Avoid stale transitional language. Describe the current architecture, not migration intent, unless historical context is needed to interpret old artifacts.

# Repo Defaults

- Prefer structural fixes over tactical patches that increase coupling.
- Do not avoid refactors when the model is wrong: changing the backend model or shared contract is better than preserving a brittle shape and compensating in the client.
- Prefer type-level and model-level prevention over runtime compensation: encode ownership, phases, permissions, and readiness in domain types where practical.
- Use the agent-native structure doctrine for nontrivial design: vertical semantic modules, pure cores, explicit effect capabilities, commands/events/reducers, algebraic laws, replayable evidence, and risk-matched verification.
- Prefer existing repo interfaces before inventing bespoke flows: `just`, Unison MCP/UCM, Xcode/simulator tooling, and checked-in scripts.
- Treat observability, verification, and repeatable debug loops as part of implementation.
- Treat documentation and testing as part of the definition of done for core Unison/backend work.
- Keep backend scope control-plane-only unless the user explicitly changes it.
- Use automated simulator scenarios and probes before physical-device debugging when the bug is not obviously Apple/PTT/audio-specific.
