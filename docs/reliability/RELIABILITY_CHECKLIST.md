# Reliability Checklist

Working checklist companion to `RELIABILITY_GUIDELINES.md`. Use during design, implementation, debugging, and release prep; do not mechanically check every box when narrower review is enough.

## 1. Design Checklist

- [ ] What exact user-visible guarantee or broken fact are we working on?
- [ ] Who is authoritative for that fact: backend, client, pair/convergence, or
      Apple boundary?
- [ ] Is the core workflow modeled as an explicit state machine?
- [ ] Are mutually exclusive states encoded as ADTs instead of booleans or
      string status fields?
- [ ] Is canonical truth stored once with projections derived from it?
- [ ] Did we separate durable truth from runtime truth?
- [ ] Do runtime facts use lease, epoch, fencing, or explicit invalidation
      semantics where needed?
- [ ] Have we defined behavior for retry, duplicate, reconnect, reorder,
      restart, refresh, and timeout?
- [ ] Is there a clear fail-closed rule when capability cannot be proven?
- [ ] If recovery is possible, is the repair bounded and idempotent?

## 2. Implementation Checklist

- [ ] Did we restate the issue as a broken invariant instead of a UI symptom?
- [ ] Did we identify the authoritative seam before editing?
- [ ] Did we add or update a stable invariant ID in
      [`invariants/registry.json`](/Users/mau/Development/bb/shared/invariants/registry.json)?
- [ ] Is invariant detection placed at the narrowest seam that can prove the
      contradiction?
- [ ] Are diagnostics machine-readable before they are rendered as text?
- [ ] Are correlation fields present where relevant: handle, device, peer,
      channel, attempt, transmit, session generation?
- [ ] Are risky transitions explicit in reducer or backend route logic rather
      than hidden in callbacks?
- [ ] Did we avoid adding a second source of truth?
- [ ] Did we avoid a frontend-only patch for a backend-owned contradiction?

## 3. Proof Checklist

- [ ] What is the narrowest proof lane for this change?
- [ ] If it is a pure app rule, do we have a targeted Swift reducer/property
      test?
- [ ] If it is backend-owned, do we have a backend test or route probe?
- [ ] If it is distributed, do we have a deterministic simulator scenario?
- [ ] If it is about retry/drop/reorder/reconnect families, should it also be
      covered by fuzzing?
- [ ] If it is about protocol semantics or all interleavings, should it also be
      covered by TLA+?
- [ ] If the issue is Apple/PTT/audio-specific, did we prove shared logic below
      that boundary first?
- [ ] Does the proof fail before the fix and pass after the fix?
- [ ] If a scenario exists, is there also a lower-level proof underneath it?

## 4. Bug Intake Checklist

- [ ] Do we have the reporter handle and peer handle?
- [ ] Do we have the `incidentId` if shake-to-report was used?
- [ ] Do we know whether this was simulator, debug device, TestFlight, or
      production-like?
- [ ] Did we run `just reliability-intake` or
      `just reliability-intake-shake`?
- [ ] Did we classify ownership before deciding on a fix?
- [ ] Did we restate the bug in this form?

```text
observer -> subject -> initial conditions -> event sequence -> expected
invariant -> observed violation
```

- [ ] Did we turn the evidence into a replay, invariant, scenario, or lower
      level regression?

## 5. Self-Healing Checklist

- [ ] Is the bad state provably invalid rather than just temporarily in flight?
- [ ] Is the repair owned by the subsystem that owns the truth?
- [ ] Is the repair idempotent?
- [ ] Is the repair bounded by timeout, callback, attempt ID, or explicit state?
- [ ] While repair is pending, does the system fail closed?
- [ ] Did we emit both invariant evidence and repair evidence?
- [ ] Do we have proof that the bad state repairs?
- [ ] Do we have proof that a nearby valid in-flight state does not repair?

## 6. Backend Review Checklist

- [ ] Which backend facts here are durable and which are runtime-only?
- [ ] Could a stale row or secondary index be misread as current truth?
- [ ] Are projections derived from authoritative facts rather than treated as
      truth themselves?
- [ ] Are secondary indexes updated transactionally with primary rows?
- [ ] Are reset/dev-cleanup paths updated for any new projections?
- [ ] Is the route/query shape aligned with the actual read pattern?
- [ ] If persisted types changed, did we follow
      [`MIGRATIONS.md`](/Users/mau/Development/bb/docs/backend/MIGRATIONS.md)?

## 7. App Review Checklist

- [ ] Are UI surfaces rendering derived state rather than owning truth?
- [ ] Are user actions normalized into typed events?
- [ ] Are reducer transitions deterministic and inspectable?
- [ ] Are state-specific payloads inside their matching enum cases?
- [ ] Could duplicate callbacks or stale completions produce contradictions?
- [ ] Do rejected events and ignored transitions leave clear diagnostics?
- [ ] Are local guards aligned with backend authority instead of diverging from
      it?

## 8. Tool Selection Checklist

- [ ] Field/device/TestFlight report:
      `just reliability-intake` or `just reliability-intake-shake`
- [ ] Pure Swift rule:
      `just swift-test-target <name>` or `just swift-test-suite`
- [ ] Backend-owned rule:
      Unison MCP/UCM, backend tests, `just route-probe`, `just route-probe-local`
- [ ] Distributed journey:
      `just simulator-scenario <name>`, `just simulator-scenario-suite`
- [ ] Pair/convergence contradiction:
      `just simulator-scenario-merge-strict`
- [ ] Failure families and perturbations:
      `just simulator-fuzz-local`, replay, shrink
- [ ] Protocol interleavings:
      `just protocol-model-checks`
- [ ] Hosted confidence:
      `just reliability-gate-*`, `just postdeploy-check`
- [ ] Staging backend proof:
      `just beepbeep-backend-staging-gate` and `just postdeploy-check`

## 9. Release Checklist

- [ ] Which gate matches the blast radius of this change?
- [ ] Did we run the narrow proof first before broader gates?
- [ ] If backend behavior changed, was the backend actually deployed?
- [ ] If the release touched shared truth, did we run hosted verification?
- [ ] If the release touched Apple/PTT/audio boundaries, was device verification
      run after lower-level proof?
- [ ] Do we have artifacts we can inspect if the release looks flaky?

## 10. Recurring Review Checklist

Use this periodically across the codebase, not just per bug:

- [ ] Which important facts still have ambiguous ownership?
- [ ] Which areas still rely on booleans or strings where ADTs should exist?
- [ ] Which runtime facts still lack lease/epoch/fencing discipline?
- [ ] Which active invariants still lack narrow regression proof?
- [ ] Which scenarios still need a lower-level test underneath them?
- [ ] Which production failures have not yet been turned into deterministic
      replays or regressions?
- [ ] Which deploy checks are still noisy rather than semantically crisp?
- [ ] Which diagnostics still flatten typed state into prose too early?
