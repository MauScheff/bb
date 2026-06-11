# Agent-Native System Structure

Status: standing architecture doctrine.

Use this when designing a new subsystem, refactoring a module boundary, naming ownership, modeling state, adding effect surfaces, or choosing verification. Do not load this for every small task; `AGENTS.md` and `WORKFLOW.md` route ordinary work.

## Purpose

An agent-native codebase is executable algebra over explicit state.

Each important module should be a small semantic world:

```text
typed data
+ legal transitions
+ algebraic operations
+ explicit effects
+ machine-checkable laws
+ composable boundaries
+ replayable evidence
```

Humans need readable files. Agents need constrained search space: types, laws, contracts, invariants, state machines, effect algebras, and verification.

## Fast Path

Default to this structure when creating or reshaping code:

| Rule | Meaning |
| --- | --- |
| Model truth first | Start from legal states, facts, transitions, and invariants before APIs, tables, UI, or vendors. |
| Prefer vertical semantic modules | Organize by domain concept, not by `controllers/services/repositories/utils`. |
| Make illegal states unrepresentable | Use ADTs, branded IDs, typed phases, explicit absence, and typed failure. |
| Represent mutation as time | Use commands, events, reducers, state machines, leases, epochs, and tombstones where state changes matter. |
| Keep the core pure | Domain logic should not import clocks, network, storage, global config, logging side effects, or frameworks. |
| Model effects as capabilities | IO is explicit, typed, swappable, simulatable, and governed by failure semantics. |
| State algebraic laws | Idempotency, commutativity, associativity, monotonicity, and compensation rules must be visible. |
| Compose by contracts | Modules expose types, commands, events, queries, required effects, invariants, laws, and failure modes. |
| Verify by risk | Types and invariants first, then examples, properties, fuzzing, replay, contracts, model checks, and runtime checks. |
| Promote failures into memory | Incidents, fuzz failures, and counterexamples become replay fixtures, scenarios, contracts, or invariant checks. |

## Abstraction Stack

Build from most fundamental to most concrete:

```text
1. Values
2. Types
3. Invariants
4. Pure functions
5. Algebraic operations
6. State machines
7. Events
8. Commands
9. Effect algebras
10. Interpreters
11. Workflows
12. APIs
13. Runtime wiring
14. Observability
15. Verification
```

Do not start from database tables, REST endpoints, service classes, UI screens, or vendor APIs. Start from:

```text
What states are legal?
What facts can happen?
What transitions are allowed?
What effects are needed?
What laws must hold under retry, concurrency, failure, and replay?
How will the system falsify itself?
```

## Module Contract

A module should answer these questions without reading its internals:

```text
What data exists?
What states are legal?
What transitions are legal?
What operations are pure?
What operations are effectful?
Which effects are required?
Which operations are retry-safe?
Which operations commute?
Which operations are idempotent?
Which invariants must never break?
How can this module be simulated?
How can this module be replayed?
How can this module compose with others?
How can this module be falsified, fuzzed, and verified?
```

Prefer this boundary:

```text
module
|-- domain        ADTs, branded IDs, value objects, errors
|-- state         commands, events, reducers, transition tables
|-- policies      pure decisions and permission/readiness rules
|-- effects       required capabilities and failure semantics
|-- workflows     declarative process/saga coordination
|-- adapters      production/test/simulation/replay interpreters
|-- api           external command/query surface
|-- contracts     versioned schemas, compatibility, generated clients
`-- verification  examples, properties, fuzzing, replay, contracts, models
```

The outer organization should be semantic. The inner organization should be predictable.

## Module Manifest

When a module becomes important or hard to reason about, give agents a compact manifest:

```yaml
module: payments
version: 3

owns:
  - Payment
  - PaymentState
  - PaymentEvent

exposes:
  commands:
    - AuthorizePayment
    - CapturePayment
  events:
    - PaymentAuthorized
    - PaymentCaptured
  queries:
    - GetPaymentStatus

requires:
  effects:
    - Clock
    - PaymentGateway
    - EventStore
    - IdGenerator

invariants:
  - captured_amount <= authorized_amount
  - payment cannot be captured before authorization

laws:
  - CapturePayment is idempotent by capture_id
  - Payment events are append-only
  - Duplicate gateway webhooks are ignored

verification:
  examples: required
  property_tests: required
  fuzz_tests: required_at_boundaries
  replay_tests: required_for_incidents
  model_tests: required_for_state_machines

risk:
  external_side_effects:
    - card_charge
  requires_reconciliation: true
```

The manifest is not bureaucracy. It is a semantic index for humans and agents.

## State Modeling

Prefer ADTs over string statuses and optional-field bundles.

Good:

```text
PaymentState =
  NotStarted
  Authorized(authId, amount)
  Captured(captureId, amount)
  Refunded(refundId, amount)
  Failed(reason)
```

Bad:

```text
status = "captured"
captureId = null
refundId = present
amount = -10
error = present
```

Use opaque IDs, branded types, sum types for variants, product types for structured values, `Result` for recoverable failure, and optional values only for genuine absence. Avoid null, primitive obsession, and stringly typed domain logic.

For mutation, separate decision from reduction:

```text
decide: State x Command -> Effect<List<Event>>
reduce: State x Event -> State
```

Ideal flow:

```text
Command -> validate -> decide -> effects -> events -> pure reducer -> new state
```

Important state is often event-shaped. Current state should be rebuildable from facts:

```text
State = fold(reduce, initialState, events)
```

Do not use event sourcing everywhere. Use append-only facts where auditability, replay, recovery, or distributed consistency matter.

## Effects

Keep a pure center and an effectful shell.

Pure core must not directly depend on:

```text
database
network
clock
randomness
environment variables
global config
logging side effects
hidden mutation
framework state
```

Represent reality as capabilities:

```text
Clock
IdGenerator
Storage
BackendClient
AudioSession
PushToTalkAdapter
MediaTransport
DiagnosticsSink
```

Every effectful capability should state:

```text
timeout semantics
retry semantics
idempotency key or duplicate behavior
unknown-outcome behavior
partial-failure behavior
reconciliation or repair path
production/test/simulation/replay interpreter
```

Time, randomness, identity, config, and environment are effects. Pass them through capabilities so tests, replay, and simulation are deterministic.

## Algebraic Laws

State useful algebraic properties explicitly.

| Law | Meaning | Use |
| --- | --- | --- |
| Idempotent | `f(f(x)) = f(x)` | retries, duplicate delivery, webhook handling |
| Commutative | `a + b = b + a` | unordered events, parallel merges, eventual consistency |
| Associative | `(a + b) + c = a + (b + c)` | batching, streaming, partial aggregation |
| Monotonic | state only moves forward in an order | observed facts, leases, processed offsets, convergence |
| Compensatable | `do + compensate = repaired state` | sagas, external effects, partial failure |

If a law does not hold, make the ordering, fencing, lease, epoch, or compensation requirement explicit.

## Workflows

Long-running workflows should be declarative state machines or sagas when possible.

Workflow definitions should expose:

```text
start event
steps
success event per step
failure event per step
compensations
timeouts
terminal states
retry policy
idempotency keys
observability fields
```

Process managers coordinate modules by reacting to events and emitting commands. They should not own another module's internals.

Separate policies from mechanisms:

```text
Mechanism: can send push, can store event, can open audio session.
Policy: when push is allowed, when event is legal, when audio session may activate.
```

Policy should usually be pure. Mechanisms execute typed decisions.

## Composition Rules

Use directional dependencies:

```text
domain -> nothing
state -> domain
application -> domain + state + effect interfaces
adapters -> application + effect interfaces + vendors
api -> application
runtime -> api + adapters + config
```

Avoid:

```text
domain imports database
domain imports HTTP
domain imports framework
state machine calls vendor SDK directly
tests require production services
```

Avoid `utils`. Put helpers where their laws and domain meaning are clear:

```text
time
identity
validation
serialization
result
collections
money
security
observability
```

## Verification Stack

The goal is not high test coverage. The goal is high behavioral constraint density.

```text
Types prevent invalid shapes.
Invariants prevent invalid states.
Examples prevent obvious regressions.
Property tests check broad laws.
Fuzzing searches weird input and interleaving space.
Model tests compare implementation to a simpler semantics.
Contract tests check boundaries.
Replay tests preserve historical truth.
Fault injection checks recovery.
Static analysis enforces architecture.
Formal specs check high-value correctness.
Runtime verification checks production reality.
```

Minimum bar by risk:

| Risk | Verification |
| --- | --- |
| Low-risk pure helper | type checks, unit examples, property tests for declared laws |
| Normal domain module | unit tests, property tests, state-machine tests, boundary fuzzing, contracts |
| Critical module | normal tests plus replay, model-based tests, fault injection, reconciliation tests |
| Money/security/distributed ownership | critical tests plus model checking or formal spec, runtime verification, audit trail tests |

Every machine-readable claim should generate at least one executable check.

## Observability

Important operations should emit machine-readable evidence:

```text
correlationId
causationId
commandId
eventId
actor
subject
tenant or conversation
device
timestamp
idempotency key
external request ID
decision reason
failure classification
expected facts
observed facts
```

Runtime verification should distinguish:

```text
expected rejection
recoverable violation
repairable invalid state
fatal corruption
suspicious behavior
```

Do not silently continue after invariant corruption.

## Generated Artifacts

Prefer canonical specs that generate:

```text
types
schemas
state diagrams
tests
fuzz generators
contract tests
simulators
replay fixtures
dependency graphs
docs
clients
```

Generated artifacts are useful only when their source of truth is explicit and checked.

## BeepBeep Application

Do not force a generic folder rewrite onto the existing repo. Use this as the target shape when changing ownership, extracting modules, or making hard behavior explicit.

Current mappings:

| Doctrine | BeepBeep equivalent |
| --- | --- |
| Pure domain kernel | `client/ios/Packages/TurboEngine` and Unison `beepbeep.*` kernel definitions |
| Effect shell | Swift adapters, backend Rust runtime/effects, Apple PTT/audio, network clients |
| Commands/events/reducers | `TurboEngine` intents, events, effects, reducer state, backend command routes |
| Invariant registry | `shared/invariants/registry.json` and `docs/reliability/INVARIANTS.md` |
| Runtime contracts | `shared/contracts/app_contract_manifest.json` and `DiagnosticsContracts.swift` |
| Replay/scenario memory | engine traces, `shared/scenarios/`, fuzz artifacts, TLA+ counterexamples |
| Proof routing | `WORKFLOW.md`, `TESTING.md`, `TOOLING.md`, `docs/reliability/*` |

For BeepBeep work:

```text
1. Locate the authoritative owner.
2. Express the behavior as typed state, event, command, invariant, law, or capability.
3. Fix the owner instead of compensating in a projection.
4. Add or reuse the narrowest executable proof.
5. Preserve production-capable evidence when recurrence would be hard to explain.
```

## Design Checklist

Before accepting a nontrivial module or refactor, answer:

```text
Can an agent identify the owner without reading unrelated files?
Are illegal states unrepresentable or guarded by named invariants?
Are transitions explicit?
Are effects typed and swappable?
Are retry, duplicate, timeout, and unknown outcomes specified?
Are durable facts separated from runtime facts?
Are projections rebuildable or clearly disposable?
Are policies separated from mechanisms?
Are algebraic laws visible?
Can the behavior be simulated?
Can historical incidents be replayed?
Is the narrowest proof lane obvious?
Does production evidence carry expected/observed facts?
```

Ideal phrase:

```text
ADTs for shape, state machines for time, algebras for composition, effects for reality, tests and proofs for trust.
```

Deep default:

```text
Organize code around what remains true under change, retry, concurrency, failure, and composition.
```
