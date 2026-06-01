# TLA+ Formal Modeling

TLA+ is Turbo's lightweight formal-modeling lane for protocol correctness and invariant discovery. Use it before or beside simulator scenarios for distributed interleavings:

- retries
- reconnects
- stale snapshots
- dropped, duplicated, or reordered signals
- lease expiry
- wake-token fallback
- app/backend projection freshness
- ownership of distributed truth

TLA+ is not final implementation proof. Final proof lives in Swift tests, Unison regressions, simulator scenarios, merged diagnostics, probes, and physical-device checks for Apple boundaries.

## What TLA+ Adds

Fuzzing and simulator scenarios ask:

> Can the current implementation fail for this generated or checked-in event
> sequence?

TLA+ asks:

> Can this protocol design reach an illegal state for any possible interleaving
> inside a bounded model?

TLA+ is best for discovering unnamed invariants. Treat TLC counterexamples as design review artifacts: classify valid/invalid/underspecified, then encode the decision in normal proof surfaces.

## Current Model

The communication model lives in:

- [`specs/tla/TurboCommunication.tla`](specs/tla/TurboCommunication.tla)
- [`specs/tla/TurboCommunication.cfg`](specs/tla/TurboCommunication.cfg)
- [`specs/tla/README.md`](specs/tla/README.md)

It models the direct-channel communication kernel:

- direct channel membership
- request, decline, accept, and local join success/failure
- joined/offline presence
- receiver audio readiness
- token-backed wake addressability
- active transmit ownership
- unreliable signal delivery
- explicit client refresh from backend truth

It intentionally abstracts over audio frames, SwiftUI, HTTP serialization,
Unison storage mechanics, PushToTalk system UI, and APNs internals.

The restart/session-generation model lives in:

- [`specs/tla/TurboSessionGeneration.tla`](specs/tla/TurboSessionGeneration.tla)
- [`specs/tla/TurboSessionGeneration.cfg`](specs/tla/TurboSessionGeneration.cfg)

It models app session generations, current-session presence, active-channel
projection, receiver readiness, active transmit ownership, and guarded backend
snapshot replay. It is intentionally separate from the full communication model
so the default communication check stays tractable.

The self-hosted Talk Turn actor model lives in:

- [`specs/tla/TurboTalkTurnActor.tla`](specs/tla/TurboTalkTurnActor.tla)
- [`specs/tla/TurboTalkTurnActor.cfg`](specs/tla/TurboTalkTurnActor.cfg)

It models runtime owner leases, one active Talk Turn, stale release fencing,
lease expiry, policy downgrade, drain/reconnect, and participant disconnects.

## Run It

Use the repo harness when you want both the model check and the Swift
implementation-side property tests:

```sh
just protocol-model-checks
```

Run the focused session-generation model without Swift property tests:

```sh
just protocol-session-generation-model-check
```

Run the focused self-hosted Talk Turn actor model without Swift property tests:

```sh
just protocol-talk-turn-actor-model-check
```

The recipe assumes `tla2tools.jar` is at `/tmp/tla2tools.jar`. If it lives
elsewhere, set `TLA2TOOLS_JAR` or pass the jar path as the first recipe
argument:

```sh
just protocol-model-checks /path/to/tla2tools.jar
```

Download or install `tla2tools.jar` if you want to run TLC directly. Then run:

```sh
cd specs/tla
java -cp /path/to/tla2tools.jar tlc2.TLC \
  -deadlock \
  -config TurboCommunication.cfg \
  TurboCommunication.tla
```

For a one-off local run, downloading the jar outside the repo is fine:

```sh
curl -L --fail -o /tmp/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar

cd specs/tla
java -cp /tmp/tla2tools.jar tlc2.TLC \
  -deadlock \
  -config TurboCommunication.cfg \
  TurboCommunication.tla
```

The harness writes `protocol-model-checks.json`, `tlc-output.txt`,
`swift-property-tests-output.txt`, and `reproduce.sh` under
`/tmp/turbo-protocol-model-checks` by default. TLC writes generated state data
under `specs/tla/states/`; that path is ignored.

## Development Cycle

Use this loop for protocol-level reliability work:

1. Pick a narrow subsystem.
   - Example: active transmit, readiness, wake targeting, reconnect freshness.
2. Model only authoritative facts and meaningful events.
   - Backend truth should usually be separate from client projection.
3. Add the obvious safety invariants.
   - Example: active transmitter must be a joined channel member.
4. Run TLC.
5. For each counterexample, classify the reached state:
   - valid: update the model or product vocabulary to make that state explicit
   - invalid: name it as an invariant
   - underspecified: decide ownership and make the state typed
6. Promote invalid counterexamples into repo-native proof:
   - register runtime-visible invariant IDs in `invariants/registry.json`
   - add Swift or Unison lower-level regressions for pure rules
   - add deterministic `scenarios/*.json` regressions for app/backend journeys
   - add or strengthen fuzz oracles when the bug is a generated-family risk
7. Keep the TLA+ invariant so future protocol edits are checked at the design
   level.

The goal is not to prove everything in one giant spec. Small models that create
useful counterexamples are better than a broad model nobody trusts.

## How It Integrates With Existing Proof Lanes

| Lane | Role |
| --- | --- |
| TLA+ | Explore bounded protocol state space and discover missing invariants. |
| Swift reducer/property tests | Prove pure client rules and local projection behavior. |
| Unison tests/probes | Prove backend-owned rules and route/store semantics. |
| Simulator scenarios | Prove concrete distributed app/backend journeys. |
| Simulator fuzzing | Generate many implementation-level event sequences and perturbations. |
| Merged diagnostics | Rediscover invariant violations across device/backend artifacts. |
| Physical devices | Verify Apple/PTT/audio/background boundaries. |

Counterexamples should flow downward:

```text
TLA+ trace
  -> named invariant
  -> lower-level Swift/Unison regression
  -> simulator scenario or fuzz oracle
  -> merged diagnostics visibility
```

Production or device failures can flow upward too:

```text
bug report or diagnostics trace
  -> suspected invariant
  -> small TLA+ model edit
  -> TLC counterexample or proof
  -> implementation regression
```

## When To Add A New TLA+ Model

Add or extend a model when:

- the state space is about ordering, duplication, loss, retry, or reconnect
- the product behavior depends on convergence between devices
- the backend is authoritative but the client can be stale
- a bug report suggests a missing invariant rather than a simple implementation
  mistake
- a design has several plausible ownership choices and needs a typed rule

Avoid TLA+ when:

- the issue is a single deterministic function with a normal unit test shape
- the problem is rendering or copy
- the result depends primarily on real Apple framework behavior
- the model would need so much implementation detail that a scenario test would
  be clearer

## Modeling Rules

Keep models small and explicit:

- model backend truth separately from client projection
- model unreliable delivery as actions, not timing sleeps
- use bounded queues and finite device/channel sets
- make stale information visible as state
- prefer safety invariants first
- add liveness only when the implementation has a real bounded progress
  mechanism, such as lease expiry or retry

Every model should document:

- what subsystem it represents
- what it intentionally abstracts away
- how variables map to repo owners
- how to run TLC
- the last verified TLC result
- which counterexamples became repo invariants or scenarios
