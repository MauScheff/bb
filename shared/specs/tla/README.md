# TLA+ Specs

Status: active formal-model reference.
Authority: bounded communication and session-generation models under
`shared/specs/tla`. The Rust runtime Talk Turn actor model lives under
`backend/specs/tla` because backend readiness gates assert that owner path.
Related docs: [`TLA_PLUS.md`](/Users/mau/Development/bb/docs/reliability/TLA_PLUS.md), [`FINDINGS.md`](/Users/mau/Development/bb/shared/specs/tla/FINDINGS.md), [`COVERAGE.md`](/Users/mau/Development/bb/shared/specs/tla/COVERAGE.md).

Use these specs for invariant discovery and protocol validation. They do not replace Swift tests, backend regressions, simulator scenarios, or diagnostics. A TLC counterexample must be classified, named as an invariant when invalid, then promoted into repo-native proof.

## Specs

| Spec | Scope |
| --- | --- |
| `TurboCommunication.tla` | Direct-channel kernel: membership, request/decline/accept, local join success/failure, joined/offline presence, receiver audio readiness, wake tokens, transmit epochs, one active transmitter, unreliable control delivery, stale projections, explicit refresh. |
| `TurboCommunication.cfg` | Default two-device/one-channel bound plus finite `MaxInboxLength`; small traces are easier to promote into `shared/scenarios/*.json`. |
| `TurboSessionGeneration.tla` | Restart/session-generation kernel: generation-bearing presence, active channel, receiver readiness, active transmit, and snapshot acceptance guarded by current app session plus membership evidence. |
| `backend/specs/tla/TurboTalkTurnActor.tla` | Self-hosted Rust Conversation actor: one runtime owner, one active Talk Turn, renewal, stale release fencing, lease expiry, policy downgrade, drain/reconnect, and participant disconnects. |

`TurboSessionGeneration.tla` is separate because session generation is high-risk and would make the full signal-delivery state space too broad for default checks.

## Repo Mapping

| TLA+ variable | Repo owner |
| --- | --- |
| `request` | backend Beep/request relationship |
| `localJoinIntent` | Swift pending local PTT join action |
| `members` | `turbo.store.memberships` |
| `presence` | `turbo.store.presence` |
| `receiverReady` | `turbo.store.receiverAudioReadiness` |
| `wakeToken` | `turbo.store.tokens` |
| `activeTransmit` | `turbo.store.runtime` |
| `transmitEpoch` | `turbo.store.runtime` active-transmit attempt/lease generation |
| `inbox` | `turbo.service.ws`, APNs wake notices, route refresh gaps |
| `knownTransmit` | Swift selected Conversation/backend snapshot projection |
| `knownEpoch` | Swift selected Conversation/backend freshness projection |
| `clientPhase` | Swift selected Conversation phase projection |
| `sessionGeneration` | app/backend session identity and reconnect ownership |
| `connected` | app websocket/session liveness abstraction |
| `presenceGeneration` | backend/app evidence that presence belongs to current app session |
| `activeChannelGeneration` | backend/app evidence that active-channel projection belongs to current app session |
| `receiverReadyGeneration` | backend/app evidence that readiness belongs to current app session |

The specs intentionally abstract over HTTP, Unison storage mechanics, SwiftUI, audio frames, PushToTalk system UI, and APNs internals.

The Talk Turn actor spec intentionally models the Rust runtime/Postgres/Redis
control-plane ownership boundary and is checked with
`just protocol-talk-turn-actor-model-check`.

## Commands

```sh
just protocol-model-checks
just protocol-session-generation-model-check
just protocol-talk-turn-actor-model-check
```

`just protocol-model-checks` validates the config, runs TLC, and runs Swift property tests for implementation-side projection and transport-fault rules.

Direct TLC run:

```sh
java -cp /path/to/tla2tools.jar tlc2.TLC \
  -deadlock \
  -config TurboCommunication.cfg \
  TurboCommunication.tla
```

For the VS Code TLA+ extension, open `TurboCommunication.tla` and run with `TurboCommunication.cfg`.

## Counterexample Promotion

1. Classify the reached state as invalid, valid, or underspecified.
2. If invalid, name the broken truth as an invariant.
3. Add the invariant to the TLA+ spec.
4. Add runtime-visible detection to `shared/invariants/registry.json` when app, backend, or merged diagnostics can detect it.
5. Convert cross app/backend traces into deterministic `shared/scenarios/*.json`.
6. Add lower-level Swift or Unison regression for the pure prevention rule.

A counterexample can be a product bug, a missing typed state, or a missing ownership rule. Promote ambiguity into an explicit invariant or ADT case.

## Current Invariants

`TurboCommunication.tla` checks:

- direct channels have at most two members
- wake tokens only exist for current channel members
- receiver readiness only exists for joined devices
- active transmitter is a joined channel member
- every active transmit has an addressable receiver
- client `receiving` projection requires local transmit evidence
- client `transmitting` projection requires local transmit evidence
- disconnected clients cannot project `receiving` or `transmitting`

`TurboSessionGeneration.tla` checks:

- joined presence belongs to current app session and current membership
- active channel belongs to current app session and current membership
- receiver readiness belongs to current joined session
- active transmit is owned by a current joined sender

`TurboTalkTurnActor.tla` checks:

- one runtime owner slot per Conversation
- at most one active Talk Turn per Conversation
- renewal extends a current active Talk Turn without changing ownership or epoch
- stale releases do not clear newer grants
- active Talk Turns have unexpired leases, an owner, and connected participants, or expire when not renewed
- policy downgrade revokes active grants
- drain requires reconnect without durable Conversation loss
- draining actors do not grant new Talk Turns

These are conservative safety rules. Add stronger convergence properties after the safety model remains stable.

## Design Notes

Unreliable delivery is modeled with `DeliverSignal`, `DropSignal`, `DuplicateSignal`, and `RefreshClient`, which asks whether stale, missing, or duplicated control notices can create illegal projections.

Earlier TLC runs found these model gaps now captured in `FINDINGS.md` and `shared/invariants/registry.json`:

- local leave must clear live projection and any active direct-channel transmit it owns or targets
- offline wake targets must not directly project `receiving`
- transmit end/completion events need monotonic freshness evidence
- backend lease expiry is bounded convergence, not all-state safety

## Last Verified

`TurboCommunication.tla` verified on 2026-05-10 with TLC 2.19:

```text
63332923 states generated
3437005 distinct states found
0 states left on queue
No error has been found
```

Captured by `tools/scripts/protocol_model_check.py` in `/tmp/turbo-protocol-model-checks-accept-join-transmit/protocol-model-checks.json`.

`TurboSessionGeneration.tla` verified on 2026-05-10 with TLC 2.19:

```text
9057 states generated
892 distinct states found
0 states left on queue
No error has been found
```

`TurboTalkTurnActor.tla` verified on 2026-05-31 with TLC 2.19:

```text
11409 states generated
1968 distinct states found
0 states left on queue
No error has been found
```

Captured by `tools/scripts/protocol_model_check.py` in `/tmp/turbo-protocol-talk-turn-actor-model-check/protocol-model-checks.json`.
