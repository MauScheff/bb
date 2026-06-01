# TLA+ Findings

Status: active bridge from TLC counterexamples to Turbo reliability work.
Authority: modeling discoveries that should graduate into `shared/invariants/registry.json`, Swift/Unison regressions, simulator scenarios, or merged diagnostics. This file is not a substitute for those proof surfaces.

## 2026-05-10

### TLA-2026-05-10-001: local exit must clear live projection

Finding: TLC reached a state where a device left a direct channel while its client projection still said `receiving`.

| Field | Value |
| --- | --- |
| Classification | Invalid. |
| Planned invariant | `selected.live_projection_after_membership_exit` |
| Promotion | Active runtime invariant. |
| Detectors | `Turbo/AppDiagnostics.swift`, `tools/scripts/merged_diagnostics.py` |
| Regression | `TurboTests/TurboTests.swift` |
| Scenario status | Existing `noInvariantViolations` assertions catch this in checked-in journeys; add a focused membership-exit scenario only with a concrete app/backend trace. |

Expected rule:

- local leave, disconnect, stale-membership repair, or membership removal must clear live `transmitting` for the affected device
- `receiving` without local joined/session evidence is covered by `selected.receiving_without_joined_session`
- any active direct-channel transmit owned by or targeting the removed membership must end or become unreachable
- regression should cover the concrete route that removes membership while receive/transmit UI is live

### TLA-2026-05-10-002: offline wake target must not directly project receiving

Finding: after modeling token-backed wake addressability, TLC found an offline token-backed receiver could move directly to `receiving` from transmit-start notice or backend refresh.

| Field | Value |
| --- | --- |
| Classification | Invalid. |
| Planned invariant | `selected.receiving_without_joined_session` |
| Promotion | Active runtime invariant. |
| Detectors | `Turbo/AppDiagnostics.swift`, `tools/scripts/merged_diagnostics.py` |
| Regression | `TurboTests/TurboTests.swift` |
| Scenario status | `background_wake_refresh_stability` proves wake-capable background state remains non-violating; `background_wake_transmit_does_not_project_receiver` proves local wake-target lane does not project background receiver as `receiving` without joined/session evidence. |

Expected rule:

- wake-token addressability may target APNs/wake but cannot project local `receiving`
- local `receiving` requires joined/session/activation evidence owned by app or Apple boundary
- wake-capable offline Friend must move through wake, reconnect, and activation before live receive projection

### TLA-2026-05-10-003: transmit notices need freshness

Finding: the unversioned model allowed old transmit-ended notices to race with a newer transmit attempt. The model now uses `transmitEpoch` and message `epoch` fields so stale `TransmitEnded` cannot clear newer active transmit.

| Field | Value |
| --- | --- |
| Classification | Invalid if implementation has no equivalent freshness guard. |
| Promoted invariant | `transmit.stale_end_overrides_newer_epoch` |
| Status | Active runtime invariant. |
| Detectors | `Turbo/TransmitCoordinator.swift`, `Turbo/AppDiagnostics.swift` |
| Regression | `TurboTests/TurboTests.swift`, `shared/scenarios/stale_transmit_stop_completion_emits_invariant.json` |
| Scenario status | Expected-violation scenario; verify with scenario runner and non-strict merged diagnostics. |

Expected rule:

- transmit start/end notices and route snapshots need monotonic attempt, generation, lease, or epoch evidence
- stale end/completion events must be ignored when a newer active transmit is known
- app-side signal reducer and backend active-transmit projection should agree on the freshness key

### TLA-2026-05-10-004: lease expiry needs bounded convergence

Finding: backend active-transmit expiry can temporarily coexist with client live projection until end notice, renew failure, timeout, or refresh. This is convergence, not all-state safety.

| Field | Value |
| --- | --- |
| Classification | Underspecified. |
| Promoted invariant | `transmit.live_projection_after_lease_expiry` |
| Status | Active convergence diagnostic. |
| Detectors | `Turbo/AppDiagnostics.swift`, `tools/scripts/merged_diagnostics.py` |
| Regression | `TurboTests/TurboTests.swift`, `shared/scenarios/lease_expiry_renewal_delay_recovers.json` |
| Scenario status | Delays first `renew-transmit` past lease expiry; delayed renewal failure plus explicit channel refresh must converge both Friends to `ready` without emitting the invariant. Verify with `just simulator-scenario-merge-local-strict`. |

Expected rule:

- backend lease expiry must become visible to sender and receiver through a bounded path
- sender must not continue outbound audio indefinitely after backend lease loss
- stale `transmitting`/`receiving` after expiry should diagnose if it outlives the allowed grace window
- regression models dropped end-notice visibility through delayed renewal failure plus eventual refresh

### TLA-2026-05-10-005: declined Beep must clear sender connection projection

Finding: `beep_decline` found backend truth idle for both Friends, sender with no pending action/local join/system session, but sender projection stuck at `waitingForPeer(reason: pendingJoin)` and `Connecting...`.

| Field | Value |
| --- | --- |
| Classification | Invalid. |
| Planned invariant | `selected.backend_idle_without_local_evidence_still_connecting` |
| Promotion | Active runtime invariant and focused regression. |
| Detector | `Turbo/AppDiagnostics.swift` |
| Regression | `TurboTests/TurboTests.swift`, `shared/scenarios/beep_decline.json` |
| Reproduction | `just simulator-scenario-local beep_decline`; `just simulator-scenario-merge-local` |
| Observed sender | `selectedConversationPhase=waitingForPeer`, `selectedConversationPhaseDetail=waitingForPeer(reason: pendingJoin)`, `pendingAction=none`, `isJoined=false`, `systemSession=none`, `backendChannelStatus=idle`, `backendSelfJoined=false`, `backendPeerJoined=false` |
| Observed recipient | idle, no pending action, no joined/session evidence, backend idle |

Expected rule:

- declined Beep must clear sender outgoingBeep/connecting projection once backend Beep Thread projection and membership are gone
- timeout recovery must update phase and status, not only emit timeout diagnostic
- repeated backend idle refreshes must idempotently converge the selected Conversation to idle when no pending local action or Device PTT evidence exists

### TLA-2026-05-10-006: local join failure can remove the only wake-addressable transmit target

Finding: expanded request/accept/local-join/transmit model exposed this trace:

1. Bob requests Alice.
2. Alice accepts, creating direct-channel membership and pending local join intent on both devices.
3. Alice completes local join.
4. Bob uploads wake token while still pending local join, becoming the only addressable receiver.
5. Alice begins transmitting.
6. Bob local join fails and his channel membership is removed.

The first expanded model left `activeTransmit=alice`, violating `ActiveTransmitHasAddressableReceiver`: active transmit needs a joined receiver or token-backed wake receiver that is still a channel member.

| Field | Value |
| --- | --- |
| Classification | Invalid protocol state; implementation ownership is backend-side. |
| Promotion | Modeled and covered by existing backend invariant family. |
| Model change | `FailLocalJoin` uses `ShouldClearTransmitAfterMembershipLoss`; `LeaveChannel` uses the same helper; model includes `RequestConnection`, `DeclineRequest`, `AcceptRequest`, `CompleteLocalJoin`, `FailLocalJoin`. |
| Proof surfaces | `channel.active_transmit_without_addressable_receiver`, `channel.active_transmit_sender_presence_drift`, backend wake-target diagnostics, `ActiveTransmitHasAddressableReceiver`, `ActiveTransmitRequiresBothDirectMembers` |
| Latest TLC | `63332923` states generated, `3437005` distinct, depth `23`, no invariant violations. |
| Scenario gap | No focused scenario forces wake-token-only receiver, sender transmit, then receiver local join failure; add only if a concrete app/backend route exposes this trace. |

Expected rule:

- membership loss and failed local join must re-evaluate active transmit addressability
- if the removed member is transmitter or only addressable receiver, backend must clear active transmit and emit freshness-preserving transmit-ended evidence used by other membership-loss paths

### TLA-2026-05-10-007: current-generation presence snapshots still require membership ownership

Finding: the session-generation model allowed `presence=joined` for a current app session without channel membership through `ApplyPresenceSnapshot`.

| Field | Value |
| --- | --- |
| Classification | Invalid protocol state. |
| Promotion | Modeled by `TurboSessionGeneration.tla` and covered by stale-session/presence invariant family. |
| Proof surfaces | `channel.stale_membership_on_session_connect`, `channel.stale_peer_presence_projected_live`, `channel.stale_self_presence_projected_live`, `presence.offline_retained_connected_session`, `presence.stale_active_channel_on_session_connect` |
| Latest TLC | `9057` states generated, `892` distinct, no invariant violations. |
| Scenario status | Restart and stale-session recovery scenarios cover concrete traces; add membershipless-current-presence scenario only if a backend route can apply current-session joined snapshot without membership. |

Expected rule:

- session/device generations prevent stale snapshots across restart but are not enough without membership
- joined presence, active channel, receiver readiness, and active transmit must be backed by current backend membership
- offline presence snapshots must clear dependent receiver-ready, active-channel, and active-transmit projections for the affected device/channel

### TLA-2026-05-10-008: wake-token revocation must re-evaluate active transmit addressability

Finding: `ClearWakeToken` plus `ShouldClearTransmitAfterTokenClear` models that an active transmit whose only addressable receiver is a wake token must clear when that token is lost.

### TLA-2026-05-31-009: Talk Turn owner lease expiry must clear active runtime grant

Finding: the first self-hosted Talk Turn actor model allowed this bounded trace:

```text
claim runtime owner -> grant Talk Turn -> owner lease expires before Talk Turn lease
```

The state violated `ActiveTalkTurnHasOwner`: an active Talk Turn was still present after its runtime owner lease expired.

Classification: invalid self-hosted runtime state.

Resolution:

- `TurboTalkTurnActor.tla` now clears an active Talk Turn when owner lease expiry is reached.
- `TalkTurnActor` now stores `ConversationOwner.lease_expires_at_ms`.
- `request_talk_turn` expires owner state before granting and rejects grants after owner lease expiry.
- The Rust actor records `OwnerExpired` when owner expiry clears an active Talk Turn.

Proof:

- `just protocol-talk-turn-actor-model-check /tmp/tla2tools.jar /tmp/turbo-protocol-talk-turn-actor-model-check`
- `just talk-turn-actor-test`

| Field | Value |
| --- | --- |
| Classification | Invalid if implementation keeps active transmit after last wake-addressable receiver token is revoked. |
| Promotion | Backend route and focused local simulator scenario. |
| Implementation proof | `turbo.store.tokens.delete`, `turbo.store.runtime.clearIfTargetDevice`, `turbo.service.channels.revokeEphemeralToken`, `shared/scenarios/wake_token_revocation_clears_active_transmit.json` |
| Related detector | `channel.active_transmit_without_addressable_receiver` |
| Scenario/fuzz status | Focused local scenario covers wake-token-only active transmit; fuzz generates `backgroundApp -> beginTransmit -> revokeEphemeralToken` with restart, websocket reconnect, refresh, and transport-delay perturbations. |

Expected rule:

- token revocation is backend-owned because `turbo.store.tokens` owns channel/user/device PTT tokens
- receiver token revocation must delete token and APNs-environment rows
- if revoked device is active transmit target and not current-session receiver-ready, backend active transmit must clear
- if target is current-session receiver-ready, token revocation alone does not make active transmit unaddressable

## 2026-05-11

### TLA-2026-05-11-009: active transmitter membership loss must clear transmit

Finding: `ShouldClearTransmitAfterDisconnect` requires backend active transmit to clear when active transmitter loses joined presence. Otherwise the system can retain live `self-transmitting`/`peer-transmitting` after the transmitter left.

| Field | Value |
| --- | --- |
| Classification | Invalid protocol state. |
| Proof surfaces | `ShouldClearTransmitAfterDisconnect`, `ActiveTransmitterIsJoinedMember`, `shared/scenarios/active_transmit_sender_disconnect_clears_transmit.json` |
| Scenario status | Focused local scenario is the sender membership-loss regression. |
| Fuzz status | Fuzz generates `beginTransmit -> sender disconnect` interleavings with restart, websocket reconnect, refresh, and transport-delay perturbations. |

Expected rule:

- disconnecting or leaving while actively transmitting must remove active transmit for that channel
- sender and receiver projections must converge out of live transmit after explicit refresh/reconciliation
- diagnostics must not emit `channel.active_transmit_sender_presence_drift` or `selected.live_projection_after_membership_exit` after the recovery window
