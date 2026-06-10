# Reliability Guidelines

Reliability companion to `WORKFLOW.md`. Use this for reliability-specific framing and review questions.

Related docs:

- [`RELIABILITY_PLAN.md`](/Users/mau/Development/bb/docs/reliability/RELIABILITY_PLAN.md): strategic reliability architecture and workstreams
- [`RELIABILITY_CHECKLIST.md`](/Users/mau/Development/bb/docs/reliability/RELIABILITY_CHECKLIST.md): practical checklists
- [`INVARIANTS.md`](/Users/mau/Development/bb/docs/reliability/INVARIANTS.md): invariant registry and emission rules
- [`SELF_HEALING.md`](/Users/mau/Development/bb/docs/reliability/SELF_HEALING.md): bounded repair rules

## Reliability Target

Reliability target:

> Every important claim has a clear owner, a precise invariant, a narrow proof,
> and production-visible evidence when it fails.

The Turbo reliability loop is:

```text
report -> diagnostics -> owner -> invariant/regression -> fix -> prove -> release/check
```

Practical target:

- Pure app/backend logic: make illegal states unrepresentable where possible.
- Distributed behavior: prove safety under retries, stale data, reconnects, drops, duplicates, and reordering.
- Apple/network/cloud boundaries: make them observable, fail closed, self-healing where safe, and checked by SLOs/probes.

Ask: what impossible state did we allow, who owned it, and how do we make that class impossible or detectable?

## How To Use Math

Use simple formalism:

- Model workflows as state machines: `State + Event -> NewState + Commands`.
- Use ADTs/enums instead of boolean bundles for mutually exclusive modes.
- Define invariants: "this must always be true."
- Define preconditions: "this event is only valid if..."
- Define postconditions: "after this transition, this must be true."
- Make operations idempotent, replay-safe, and order-robust.
- Use leases and epochs for runtime truth so stale facts cannot masquerade as current truth.
- Treat durable state as monotonic/convergent where possible; treat runtime state as leased, fenced, and expiring.

## Reliability-Specific Rules

- Start with ownership. Do not fix a backend-owned contradiction only in Swift because the UI showed it first.
- Treat durable facts and runtime facts differently. Runtime facts such as presence, readiness, active transmit, and wake targets need lease, epoch, fencing, tombstone, or invalidation discipline.
- Fail closed when capability cannot be proven. Do not show or authorize `ready`, `receiving`, transmit, or wake behavior from stale or incomplete evidence.
- Use self-healing only for provably invalid and safely recoverable states. Repairs must be bounded, idempotent, diagnostic-visible, and proven against nearby valid in-flight states.
- Keep production evidence in mind while designing the invariant. A bug that can happen in TestFlight or production must emit or preserve enough facts to reconstruct the contradiction.

## Tool Selection

Use the thinnest tool that proves the claim. `TOOLING.md` owns command details.

| Need | Tool |
| --- | --- |
| Pure Swift reducer/projection rule | `just swift-test-target <name>` |
| Full app-side test confidence | `just swift-test-suite` |
| Backend-owned truth | Unison MCP/UCM tests, backend probes |
| Distributed app/backend journey | `just simulator-scenario <name>` |
| Full scenario catalog | `just simulator-scenario-suite` |
| Pair/convergence diagnostics | `just simulator-scenario-merge-strict` |
| Field/TestFlight/device report | `just reliability-intake` or `just reliability-intake-shake` |
| Retry/drop/reorder/reconnect families | `just simulator-fuzz-local <seed> <count>` |
| Protocol interleavings | `just protocol-model-checks` |
| Hosted route/control-plane confidence | `just postdeploy-check`; use `just backend-stability-probe` for lower-level route availability |
| Verified production backend | `just beepbeep-backend-production-gate` and `just postdeploy-check` |
| Apple/PTT/audio boundary | Physical device check after lower layers are proven |

## Iteration Rule

1. Restate the symptom as a broken fact.
2. Decide who owns that fact: backend, client reducer, pair/convergence, or Apple boundary.
3. Add or strengthen the invariant at that owner seam.
4. Write the narrowest failing proof.
5. Fix the owner, not the visible symptom.
6. Run the narrow proof.
7. Run the right gate for the blast radius.
8. Keep diagnostics good enough that the next production failure is reconstructable.

## Recommended Changes

High-leverage directions:

- Make invariant-first work non-negotiable. Every serious bug should become a named rule in [`invariants/registry.json`](/Users/mau/Development/bb/shared/invariants/registry.json), with detection at the authoritative seam described by [`INVARIANTS.md`](/Users/mau/Development/bb/docs/reliability/INVARIANTS.md).
- Continue the backend stale-truth audit. Classify every call-critical backend fact as durable/monotonic or leased/epoched runtime state: presence, readiness, signaling authorization, wake target, active transmit, relay/session facts.
- Push more behavior into typed reducers and projections. UI should render derived state, not own truth. This direction is documented in [`SWIFT.md`](/Users/mau/Development/bb/docs/client/SWIFT.md).
- Add lower-level property/reducer tests under every simulator scenario. Scenarios are valuable but expensive; the pure invariant underneath should usually have a fast Swift or Unison proof.
- Use TLA+ for protocol questions before implementation gets complicated: reconnect, stale snapshots, duplicated/dropped/reordered signals, lease expiry, active transmitter ownership, and wake targeting. See [`TLA_PLUS.md`](/Users/mau/Development/bb/docs/reliability/TLA_PLUS.md).
- Run simulator fuzzing regularly, then promote minimized failures into checked-in scenarios only when they are stable and meaningful. See [`SIMULATOR_FUZZING.md`](/Users/mau/Development/bb/docs/reliability/SIMULATOR_FUZZING.md).
- Treat self-healing as a formal repair pattern, not a UI patch. Repairs must be bounded, idempotent, observable, and tested against nearby valid in-flight states. See [`SELF_HEALING.md`](/Users/mau/Development/bb/docs/reliability/SELF_HEALING.md).

## Good Reliability Work

Strong fix:

- one stable invariant ID
- one authoritative detector
- one lower-level proof at the owning seam
- one scenario, replay, or probe if the bug was distributed
- clear diagnostics evidence
- no new ambiguity about ownership

Weak fix:

- UI-only masking of a backend bug
- another boolean added to represent a mode
- logs without a stable invariant ID
- a scenario added without a lower-level proof underneath it
- repeated manual reproduction instead of a checked-in regression

## Review Questions

Review questions:

- What exact fact can be wrong here?
- Who is authoritative for that fact?
- Is this state modeled as an ADT or as scattered flags?
- What stale runtime fact could be mistaken for current truth?
- What happens under retry, duplicate, reconnect, reorder, refresh, restart, and timeout?
- What invariant would name the contradiction?
- Where should that invariant be detected?
- What is the narrowest proof lane?
- Can the system repair this safely and idempotently?
- If this fails in production, what evidence will we have?
