# Self-Healing

Turbo treats some bad runtime states as recoverable convergence failures, not terminal user-visible errors. Use this after an invariant identifies a safely repairable app/backend state.

## Goal

Users should not force quit, reset local state, or ask the peer to disconnect for clearly invalid, safely recoverable states.

1. detect the bad state at the authoritative seam
2. emit a stable invariant ID into diagnostics
3. choose the owner of the repair
4. run a bounded, idempotent repair action
5. project a valid user state again
6. keep enough diagnostics to explain what happened later
7. prove the recovery with a checked-in regression

While repair is pending, invalid facts are repair-only evidence. They must not authorize user action, readiness, transmit, or join shortcuts. They behave like tombstones: they move the system toward convergence but cannot become live capability.

## Recovery Classes

Classify before editing.

### Backend stale, client can prove it

Backend contains shared state that cannot be valid given local Device PTT evidence.

Example:

- backend says this device still has channel membership
- local/system PTT session is absent
- there is no pending local action that can explain the mismatch

Preferred repair:

- emit a backend/convergence invariant
- send an idempotent backend repair command, usually a leave/clear-membership operation
- refresh backend state and selected Conversation projection

Current example:

- `selected.stale_membership_friend_ready_without_session`
- `SessionReconciliationAction.clearStaleBackendMembership`
- `SelectedConversationEffect.clearStaleBackendMembership`

### Client stale, backend already converged

Backend canonical state is valid; local pending/session projection is stale.

Example:

- backend says local membership is absent
- local/system PTT session is absent
- selected Conversation still has a pending local join or leave action

Preferred repair:

- emit a local/convergence invariant when observed in diagnostics
- clear only the stale local coordinator state
- do not call backend if backend is already canonical
- update selected Conversation projection back to idle/ready

Current examples:

- `selected.backend_absent_pending_local_action_without_session`
- `SessionCoordinatorState.reconcileAfterChannelRefresh(...)`
- `PTTViewModel.completeAbsentBackendMembershipRecoveryIfLocalSessionEnded(for:)`

### Ambiguous or in flight

State may be briefly valid because request, join, leave, transmit, wake, or retry is still in progress.

Preferred behavior:

- do not repair immediately
- preserve attempt IDs, pending action kind, and timestamps
- wait for an explicit callback, backend acknowledgement, or bounded timeout
- emit an invariant only after the state is impossible or overdue

Example:

- `requestingBackend` while backend currently says membership is absent can be valid immediately after a user taps connect
- a wake-capable receiver may briefly lack full audio readiness during background activation

## Rules For Adding A Self-Heal

1. State the broken truth as an invariant.
2. Decide who owns the truth:
   - backend truth: fix or repair through backend state
   - local Apple/PTT/session truth: fix local coordinator or system-session state
   - pair truth: use merged diagnostics and usually add a simulator scenario
3. Prefer ADT/reducer changes over scattered guard clauses.
4. Make the repair idempotent. Running it twice should be harmless.
5. Bound the repair. Use a callback, attempt ID, or timeout so it cannot loop forever.
6. Log the repair as a normal diagnostic event, not only as an invariant.
7. Ensure the bad state projects to a safe user state while repair is pending.
8. Add a regression for both:
   - the bad state repairs
   - the nearby valid in-flight state does not repair

## Diagnostics Requirements

A self-heal must leave invariant evidence for classification and repair evidence for causality.

Use a stable invariant ID for the broken state, for example:

```text
selected.backend_absent_pending_local_action_without_session
```

Use a clear repair diagnostic for the actual action, for example:

```text
Recovered local session state after backend membership became absent
```

Merged diagnostics should let an agent answer:

- what invariant was violated?
- which side owned the truth?
- what repair ran?
- did the state converge afterward?

## Current Self-Healing Surfaces

App-side surfaces:

- `Turbo/AppDiagnostics.swift`
  - snapshot invariant detection
- `Turbo/ConversationDomain.swift`
  - typed session derivation and reconciliation actions
- `Turbo/SelectedConversationProjection.swift`
  - reducer effects for selected Conversation repair
- `Turbo/PTTViewModel+Selection.swift`
  - local selected Conversation recovery when backend membership is already absent
- `Turbo/PTTViewModel+PTTActions.swift`
  - selected Conversation repair effect execution
- `Turbo/PTTViewModel+BackendLifecycle.swift`
  - backend bootstrap and signaling-join drift recovery
- `Turbo/PTTViewModel+Transmit.swift`
  - transmit membership drift recovery and wake/audio send gating recovery

Backend/merged surfaces:

- backend invariant events via `/v1/dev/invariant-events/recent`
- `scripts/merged_diagnostics.py` for pair/convergence rediscovery
- `scenarios/*.json` for distributed state-machine regressions

## Current Recovery Examples

- Stuck `Disconnecting` after backend and local session are already absent:
  - clear completed local leave state
  - cancel disconnect recovery task
  - project selected Conversation back to idle

- Stale pending local join after backend membership becomes absent:
  - clear pending local join
  - keep backend unchanged because backend already converged
  - log `Recovered local session state after backend membership became absent`

- Stale backend membership without local Device PTT evidence:
  - selected Conversation derives `clearStaleBackendMembership`
  - app sends backend leave/repair
  - local projection refreshes after backend convergence

## What Not To Do

- Do not hide a bad state only by changing UI copy.
- Do not patch a backend-owned contradiction only in Swift.
- Do not clear `requestingBackend` immediately just because backend still says absent; that can be a valid in-flight connect.
- Do not add unbounded retry loops.
- Do not emit a new invariant ID for the same broken truth if an existing one already covers it.
- Do not rely on physical-device reproduction as the only proof. Add reducer/unit/scenario coverage where the state can be modeled.

## Proof Checklist

For each new self-heal:

1. Add or update the invariant detector.
2. Add the repair transition/effect.
3. Add a diagnostic record for the repair action.
4. Add a regression that starts from the bad state and asserts convergence.
5. Add a regression that nearby valid in-flight state is preserved.
6. Run `just swift-test-target <testName>` or a checked-in simulator scenario.
7. If the bug is distributed, inspect merged diagnostics and add scenario coverage where practical.
