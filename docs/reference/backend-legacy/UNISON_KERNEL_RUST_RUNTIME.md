# Unison Kernel / Rust Runtime Plan

Status: historical plan, superseded for active work.
Scope: original self-hosted Turbo control-plane plan with pure Unison decision logic and a Rust effect runtime.

Active work now lives under [`backend`](/Users/mau/Development/bb/backend), uses the `beepbeep.*` Unison namespace, and targets `https://staging.beepbeep.to` as the canonical deployed base URL. Use [`backend/docs/ARCHITECTURE.md`](/Users/mau/Development/bb/backend/docs/ARCHITECTURE.md) for current architecture and `just beepbeep-backend-gate` for the active reliability lane.

Related:

- [`backend/README.md`](/Users/mau/Development/bb/README.md): active backend entrypoint.
- [`backend/docs/ARCHITECTURE.md`](/Users/mau/Development/bb/backend/docs/ARCHITECTURE.md): active architecture.
- [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md): ownership, invariant, proof, and escalation model.
- [`GLOSSARY.md`](/Users/mau/Development/bb/GLOSSARY.md): canonical Conversation, Participant, Connection, Device, and Talk Turn language.
- [`fuzz.md`](/Users/mau/Development/bb/docs/reliability/fuzz.md): current fuzz operator loop, artifact rules, replay, shrink, classify, and promote workflow.
- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/bb/docs/reliability/STATE_MACHINE_TESTING.md): scenario-worthiness and distributed proof boundaries.
- [`BACKEND.md`](/Users/mau/Development/bb/docs/backend/BACKEND.md): active backend ownership rules.
- [`BACKEND_STRUCTURE.md`](/Users/mau/Development/bb/docs/backend/BACKEND_STRUCTURE.md): legacy/reference backend namespace map.
- [`ENGINE.md`](/Users/mau/Development/bb/ENGINE.md): app/engine state and effect contract.
- [`TLA_PLUS.md`](/Users/mau/Development/bb/docs/reliability/TLA_PLUS.md): protocol model checking lane.
- [`AWS_PLAN.md`](/Users/mau/Development/bb/docs/backend/AWS_PLAN.md): adjacent older relay/BYOC/Rust live-control plan.

## Historical Decision

This document originally proposed building a parallel self-hosted backend path:

```text
iOS clients
  -> Rust runtime
       HTTP / WebSocket / QUIC / APNs / Postgres / Redis or NATS / metrics
       |
       -> Unison kernel worker
            pure domain decisions, policy, transitions, invariants, effect plans
```

That parallel path has become the active BeepBeep backend lane. Treat the remaining sections as historical design context unless a section explicitly matches a current command under `backend`.

## Architecture Rule

Rust owns effects. Unison owns meaning.

Unison kernel functions must be pure:

```text
Command + StateSnapshot + PolicySnapshot + KernelVersion
  -> Decision + EffectPlan + InvariantEvents + ReplayFacts
```

Rust interprets the effect plan:

```text
EffectPlan
  -> SQL transaction
  -> Redis/NATS publish
  -> WebSocket send
  -> QUIC send
  -> APNs request
  -> metric/log/diagnostic write
```

The Unison kernel must not import or depend on:

- `Cloud`
- `Storage`
- `Database`
- `OrderedTable`
- `Route`
- `Remote`
- `WebSockets`
- `Environment.Config`

The kernel may depend on pure domain, JSON/wire codecs, test fixtures, and invariant definitions.

## Terminology Baseline

The new kernel/runtime lane should start with the glossary's target vocabulary instead of preserving current backend storage and route names.

| New kernel/runtime term | Use for | Avoid in new domain code | Boundary exception |
| --- | --- | --- | --- |
| `Friend` | Product relationship between two people. | `peer`, `user` when relationship matters. | Auth/storage adapters may still store provider user IDs. |
| `Conversation` | Shared talk space between Friends. | `channel`, `room`, `session`. | Existing HTTP routes and Apple APIs may expose `channelId`. |
| `Participant` | A Friend's role inside a Conversation. | `peer`, unqualified `member`. | SQL join tables may use `participant` or `conversation_participant`. |
| `Connection` | Delivery path that moves voice inside a Conversation. | unqualified `transport`, `connected`. | Low-level QUIC/TCP modules may use transport terms. |
| `TalkTurn` | One push-to-talk speaking interval. | `transmit`, `transmission`, `active speaker`. | Existing Cloud route comparison may adapt `/begin-transmit` to `RequestTalkTurn`. |
| `Device` | Phone/platform capability and identity. | generic `client`, `endpoint` for domain facts. | Socket and QUIC code may use endpoint for network addresses. |

New Unison kernel types should prefer names such as:

```text
ConversationId
ParticipantId
ConversationSnapshot
ConversationPolicySnapshot
RequestTalkTurnCommand
TalkTurnDecision
TalkTurnEffectPlan
TalkTurnEpoch
ConnectionPath
DeviceReadiness
```

Restricted names may remain inside adapters:

- `channelId` when translating current HTTP routes, Apple PushToTalk APIs, or legacy Cloud storage.
- `sessionId` for socket/QUIC/runtime sessions.
- `peer` inside existing relay internals until the relay module is extracted and renamed by meaning.
- `transmit` inside compatibility probes or current Cloud route comparison.

Initial naming ledger for the new lane:

| Old/current term | New kernel/runtime term | Scope |
| --- | --- | --- |
| `ChannelId` | `ConversationId` | Kernel/domain snapshots and new self-hosted routes. |
| channel member | `Participant` | Conversation authorization and Talk Turn decisions. |
| sender | requesting `Participant` | Talk Turn request decisions. |
| receiver | target `Participant` | Talk Turn target selection and wake readiness. |
| active transmit | current `TalkTurn` | Runtime lease and DB constraints. |
| begin-transmit | `RequestTalkTurn` | Kernel command and new route semantics. |
| end-transmit | `ReleaseTalkTurn` | Kernel command and actor protocol. |
| peer | `Friend` or `Participant` | Friend for relationship; Participant inside Conversation/Connection logic. |

## Parallel Namespace

Keep current backend namespaces intact. Add new pure namespaces instead of rewriting the existing Cloud store/service path in place:

| Namespace | Purpose |
| --- | --- |
| `beepbeep.domain` | Pure shared domain types for the self-hosted path. |
| `beepbeep.snapshot` | State and policy snapshot types consumed by decisions. |
| `beepbeep.command` | Wire-facing command ADTs. |
| `beepbeep.decision` | Decision and denial/grant ADTs. |
| `beepbeep.effect` | Effect-plan ADTs interpreted by Rust. |
| `beepbeep.invariants` | Pure invariant detectors and replay facts. |
| `beepbeep.codec` | Stable JSON/CBOR codec boundary for Rust interop. |
| `beepbeep.tests` | Golden, property, and replay tests. |

Existing `turbo.domain`, `turbo.store.*`, and `turbo.service.*` remain the Cloud backend authority until explicit cutover.

## Runtime Components

| Component | Owner | Responsibility |
| --- | --- | --- |
| Rust API/runtime | Rust | Public HTTP, WebSocket, QUIC, APNs, DB pools, Redis/NATS, timeouts, metrics, tracing, worker lifecycle. |
| Unison kernel worker | Unison | Pure command decisions, invariant checks, effect-plan construction, replay. |
| Postgres | Rust | Durable Friends/users, Devices, Conversations, Participants, Beep Threads, tokens, readiness, control events, diagnostics metadata. |
| Redis or NATS | Rust | Live device-to-node routing, TTL presence, pub/sub, short-lived idempotency, optional live lease coordination. |
| Object storage | Rust | Large diagnostics blobs and support artifacts if needed. |
| Current Unison Cloud backend | Existing path | Production/comparison lane until the self-hosted path proves parity. |

Default v1 storage recommendation: Postgres plus Redis. Add NATS when cross-node realtime routing becomes clearer than Redis pub/sub.

## Existing Rust Relay Reuse

Turbo already has a Rust relay in [`relay/`](/Users/mau/Development/bb/relay) with:

- QUIC datagram packet media over UDP `443`
- TCP/TLS ordered fallback over TCP `443`
- in-memory relay sessions
- canary token validation
- peer join, datagram join, forwarding, stale-peer removal, and fallback tests

Reuse it as the first transport/runtime seed, but do not let the current relay binary become the whole self-hosted backend unchanged.

Required extraction before integration:

| Current shape | Target shape |
| --- | --- |
| `relay/src/main.rs` owns protocol, state, IO, config, and process lifecycle. | Split reusable modules or crates: `protocol`, `relay_state`, `transport_quic`, `transport_tcp`, `auth`, `metrics`, `runtime`. |
| Shared canary token. | Kernel/Rust-issued scoped session token or signed relay grant. |
| In-memory sessions only. | In-memory for single-instance stage; owner routing or sticky rendezvous before multi-instance. |
| Media relay only. | Transport module under a broader Rust runtime that also owns HTTP, WebSocket, DB, APNs, metrics, and kernel IPC. |
| Relay-specific diagnostics. | Unified runtime diagnostics with route, websocket, QUIC, kernel, DB, and APNs timing. |
| Relay `peer` vocabulary. | `Participant` in domain/runtime authority; `peer` remains allowed only inside legacy relay adapter code. |

Good reuse:

- keep the QUIC/TCP listener code path as the initial media/control transport implementation
- keep packet-vs-ordered fallback rules
- keep stale peer removal and duplicate join tests
- keep the probe binary as a transport health tool
- extract relay protocol frames into a library used by server, probes, and Swift-facing docs

Do not reuse:

- shared empty token as production auth
- one-process session map as a hidden horizontal-scaling solution
- relay-specific peer/session vocabulary for durable Conversation or Talk Turn authority
- QUIC stream audio as a substitute for packet media

## IPC Boundary

Start with a long-lived local worker protocol.

Preferred first implementation:

```text
Rust process starts one or more Unison kernel workers.
Rust sends length-prefixed JSON requests over stdio or Unix domain socket.
Unison returns length-prefixed JSON responses.
Rust logs every request/response hash for replay.
```

Rules:

- No Unison call per audio packet, heartbeat, websocket ping, or QUIC datagram.
- At most one kernel call per semantic command.
- Prefer coarse requests over many small questions.
- Give every request a deadline.
- Treat worker restart as normal: reject nonessential commands, preserve fenced live state, and drain safely.
- Switch JSON to MessagePack/CBOR only after profiling proves serialization overhead matters.

## Live Kernel Packaging

Do not make per-command `ucm run ...` the production serving path.

| Packaging mode | Use for | Keep | Avoid |
| --- | --- | --- | --- |
| `ucm run` against a local codebase | local proofs and first remote canary plumbing | fastest semantic iteration; exact codebase behavior | production request path, large image layers, per-command startup cost |
| `ucm run.compiled` against compiled `.uc` artifacts | first VM production candidate | no live codebase dependency; smaller package; stable artifact hash | ad hoc codebase mutation inside the container |
| long-lived Unison kernel worker | target runtime shape | one worker start per process, deadline-aware IPC, restart/drain policy, request/response hashing | calling Unison per audio packet, heartbeat, websocket ping, or QUIC datagram |

The first self-hosted GCP deployment target is one Compute Engine VM, not Cloud Run. The VM image packages compiled `.uc` worker artifacts plus the Rust runtime and relay binaries; it does not package the live Unison codebase. A later runtime can replace per-command `ucm run.compiled` with a resident worker process without changing the Rust-owned effect boundary.

## Compute Engine VM Lane

Owner: self-hosted runtime infrastructure.

First proof lane: `just kernel-compile`, `just rust-runtime-integration`, then `just gce-self-hosted-deploy-dry-run`.

Escalation condition: run `just gce-self-hosted-deploy` only after local runtime/storage proofs are green. Use `just gce-self-hosted-deploy-relay` only when the existing systemd relay is intentionally drained or stopped.

Artifact paths:

- kernel artifacts: `backend/infra/vm/build/kernel/*.uc`
- deploy summary: `/tmp/turbo-gce-self-hosted-deploy.json`
- VM remote root: `/opt/turbo-self-hosted`

Done condition:

- VM `docker compose ps` shows `postgres`, `redis`, and `runtime` healthy/running.
- `curl http://127.0.0.1:8091/s/turbo/v1/health` succeeds on the VM.
- Relay ownership is explicit: either the current `turbo-relay` systemd service remains active, or Docker Compose owns the `relay` profile on TCP/UDP `443`, never both.

Service shape:

| Service | VM stage | Later migration |
| --- | --- | --- |
| Rust runtime | Docker Compose service. | GKE deployment, or a managed HTTP service only if the surface is purely HTTP/WebSocket. |
| Relay | Existing systemd service initially; optional Compose `relay` profile when ready. | Dedicated relay pool or GKE/VM group with sticky rendezvous. |
| Postgres | Local persistent Docker volume. | Cloud SQL after backup/restore and latency checks. |
| Redis | Local ephemeral Docker service for TTL presence, pub/sub, and owner records. | Memorystore or removal if Postgres primitives prove sufficient. |
| Unison kernel | Compiled `.uc` artifacts executed by UCM. | Resident compiled worker over stdio or Unix socket. |

Redis rule: Redis may accelerate live coordination, but it must not become durable truth. A Redis flush may force reconnect, presence expiry, or owner-record reacquisition; it must not corrupt Conversation, Participant, Device, or Talk Turn state recoverable from Postgres.

## Snapshot Model

A state snapshot is the exact world Rust asks Unison to reason about. It is immutable for the decision.

Example `ConversationSnapshot` for requesting a Talk Turn:

```text
conversationId
requestingParticipantId
requestingDeviceId
participants
runtimeSessions
devicePresence
targetDeviceAudioReadiness
wakeTargets
currentTalkTurn
conversationSeq
snapshotBuiltAt
```

A `ConversationPolicySnapshot` is the rule/config layer applied to state:

```text
policyVersion
maxTalkTurnLeaseMs
renewWindowMs
presenceFreshnessMs
wakeFallbackEnabled
directQuicEnabled
relayEnabled
requireCurrentSessionForReadyAudio
minimumAppVersion
```

State answers "what is true now?" Policy answers "which rules apply?"

Every decision records:

- `kernelVersion`
- `policyVersion`
- `snapshotHash`
- `commandHash`
- `decisionHash`
- `conversationSeq`
- `sessionEpoch`
- `talkTurnEpoch` when applicable

## Reliability Contracts

The boundary must make Rust mistakes detectable.

| Risk | Contract |
| --- | --- |
| Rust builds an incomplete snapshot. | Kernel validates required facts and returns explicit `InvalidSnapshot`. |
| Rust uses stale policy. | Every command carries `policyVersion`; kernel can deny stale policy. |
| Rust executes effects out of order. | Effect plans include transaction groups and post-commit side effects. |
| Retry duplicates a mutation. | Commands carry idempotency keys; DB writes use unique constraints or compare-and-swap. |
| Stale release clears a newer Talk Turn. | Every release carries `talkTurnEpoch`; DB/actor checks the epoch. |
| Two Rust pods grant the same Conversation. | One Conversation has one runtime owner before active-active control is enabled. |
| Worker output cannot be audited. | Persist replay facts and request/response hashes. |

## Proof And Fuzz Architecture

The self-hosted lane should extend Turbo's existing proof system instead of replacing it.

Core rule:

```text
Unison fuzzes meaning.
Rust fuzzes effects, protocols, concurrency, and boundary interpretation.
Shared corpora make failures replayable across both.
```

Existing lanes to preserve:

| Current lane | Keep for | New self-hosted relationship |
| --- | --- | --- |
| `just engine-fuzz-corpus` | Promoted engine regressions. | Continue as app/engine semantic corpus. |
| `just engine-fuzz-local <seed> <count>` | Engine rules against current local Unison backend semantics. | Add a self-hosted base URL mode once the Rust route slice exists. |
| `just simulator-fuzz-local <seed> <count>` | App/backend/PTT-shim distributed journeys. | Reuse the generator and strict diagnostics against the self-hosted backend. |
| `just ptt-readiness-fuzz` | App adapter readiness interleavings. | Keep as Swift/app boundary proof; Rust consumes only stable readiness facts. |
| `just audio-packet-fuzz` | Media packet, transport envelope, and playout boundary. | Keep packet/audio rules outside the Unison kernel; Rust fuzzes relay/protocol frames. |
| `just reliability-fuzz-local-overnight <seed> <count>` | Broad current local reliability sweep. | Mirror with `just reliability-fuzz-self-hosted-overnight <seed> <count>`. |

| Lane | Owner | Finds | Artifact |
| --- | --- | --- | --- |
| Unison kernel examples/properties | Unison kernel | Invalid Conversation, Participant, Readiness, Talk Turn, and EffectPlan decisions. | Kernel test output plus golden request/response fixtures. |
| Kernel decision corpus | Unison + Rust | Divergence between generated kernel decisions and Rust interpretation. | `KernelRequest` / `KernelResponse` JSON or CBOR corpus. |
| Rust unit/property tests | Rust runtime | Effect interpreter bugs, DB transaction mistakes, token validation, relay state-machine regressions. | `cargo test` / property failure seed. |
| Rust parser/protocol fuzz | Rust runtime | Malformed WebSocket, QUIC, relay, kernel IPC, and JSON/CBOR frame bugs. | Fuzz corpus and minimized crashing input. |
| Rust concurrency/model tests | Rust runtime | Split ownership, stale release, drain/reconnect, actor cancellation, and cross-pod routing races. | deterministic scheduler seed or trace. |
| Self-hosted route/scenario fuzz | Distributed integration | Rust runtime plus Postgres/Redis/NATS behavior under duplicate, delayed, reordered, and stale commands. | `/tmp/turbo-self-hosted-fuzz/` run directory. |
| Shadow comparison fuzz | Platform comparison | Current Cloud backend and self-hosted runtime semantic divergence. | normalized response/state diff plus replay request. |

Promotion rules:

- A Unison kernel fuzz failure becomes a pure kernel regression first.
- A Rust effect failure becomes a Rust unit/property regression and, when semantic, a kernel fixture too.
- A parser/protocol crash becomes a minimized fuzz corpus case.
- A self-hosted scenario failure becomes the lowest deterministic proof that still crosses the failing boundary.
- A shadow comparison mismatch is classified as intended model improvement, current Cloud bug, or self-hosted bug before it enters a corpus.

Suggested Rust tools by target:

| Target | Tool class |
| --- | --- |
| state-machine and EffectPlan interpreter | property tests such as `proptest` |
| frame/codecs/parsers | coverage-guided fuzzing such as `cargo-fuzz` |
| actor/concurrency interleavings | deterministic scheduler/model tests such as `loom` or equivalent |
| HTTP/WebSocket/QUIC integration | generated scenario runner against local self-hosted services |

Every fuzz lane must stop on the first serious failure, preserve the seed/input/artifact path, replay the failure, shrink when possible, classify ownership, and promote the failure into a durable regression.

## Staged Plan

### Stage 0: Baseline And Non-Interference

Owner: backend/platform.

Goal: keep the current Unison Cloud backend untouched and measurable.

Rules:

- Do not change current Cloud route behavior for this work.
- Do not rename or rewrite existing `turbo.store.*` tables as part of kernel extraction.
- Add new kernel code under `beepbeep.*`.
- Add Rust runtime code in a new self-hosted path, not inside `relay/` unless it is genuinely media-relay code.

First proof lane:

```bash
just backend-schema-drift-test
just route-probe
just backend-stability-probe
```

Artifacts:

- hosted probe JSON
- current schema-drift result
- behavior snapshots used for comparison

Done condition:

- Current Cloud backend remains deployable and probe-green.
- New code paths are unreachable from production clients by default.

### Stage 1: Kernel Contract Slice

Owner: Unison kernel.

Goal: define the pure command/snapshot/decision/effect contract for one vertical slice.

First slice: `RequestTalkTurn`.

Required Unison functions:

```text
beepbeep.talkTurn.request :
  RequestTalkTurnCommand
  -> ConversationSnapshot
  -> ConversationPolicySnapshot
  -> TalkTurnDecision
```

Required tests:

- requesting Participant must belong to the Conversation
- target Participant must belong to the Conversation
- Ready target Participant with foreground-capable Device grants
- token-backed wake-capable target Device grants when policy allows
- existing active Talk Turn denies
- expired Talk Turn can be replaced
- stale session/readiness facts deny or repair explicitly

First proof lane:

- use Unison MCP `run_tests` for subnamespace `beepbeep.talkTurn`
- add `just kernel-test` once the namespace exists and the command can be repeated from a shell

Artifact path:

- `beepbeep.tests` watch/test results
- golden JSON request/response fixtures under the Unison codebase or generated test artifacts

Done condition:

- Pure Unison decision tests pass without Cloud abilities.
- Kernel request/response JSON is stable enough for Rust to consume, with unique Stage 1A case ids, command/snapshot/policy input envelopes, expected decision kind, audit envelope, and grant/deny effect semantics.

### Stage 1A: Kernel Fuzz Corpus

Owner: Unison kernel.

Goal: create a replayable semantic corpus for kernel decisions before Rust effects exist.

Initial corpus:

- valid `RequestTalkTurn` grant
- duplicate `RequestTalkTurn`
- stale `ReleaseTalkTurn`
- expired current `TalkTurn`
- Ready target Participant
- not-Ready target Participant
- wake-capable target Device
- stale Device readiness
- missing Participant
- malformed or incomplete `ConversationSnapshot`

First proof lane:

- use Unison MCP `run_tests` for `beepbeep.tests`
- add `just kernel-fuzz` once the generator and corpus are repeatable from a shell

Artifact path:

- kernel corpus fixtures
- generated seed and shrink output when available
- request/response hash ledger

Done condition:

- The kernel can generate, replay, and shrink semantic decision failures without Rust.
- The same fixtures can be consumed by the Rust kernel harness.

### Stage 2: Rust Kernel Harness

Owner: Rust runtime.

Goal: call the Unison kernel worker from Rust without public networking or database writes.

Shape:

```text
Rust test harness
  -> fixture KernelRequest JSON
  -> Unison worker
  -> KernelResponse JSON
  -> compare to golden result
```

First proof lane:

```bash
cargo test -q -p beepbeep-runtime kernel_harness
```

Escalation condition:

- If worker startup dominates latency, keep workers warm and add a pool.
- If JSON codec mismatches occur, fix the Unison/Rust wire schema before adding DB.

Artifact path:

- Rust golden test output
- kernel worker stderr/stdout logs
- request/response fixture hashes

Done condition:

- Rust can run many kernel decisions through a warm worker.
- Deadline, restart, malformed response, and hash mismatch cases are tested.
- Rust can replay the Stage 1A kernel corpus and detect response mismatches.

Current implementation note:

- `ProcessKernelWorker` replays the Stage 1A corpus through UCM with deadline, malformed response, hash mismatch, and restart coverage.
- `ProcessRequestTalkTurnKernelWorker` invokes the Unison request Talk Turn worker entrypoint from the live route path and records a per-invocation audit ledger with command, snapshot, policy, request, and response hashes, decision kind, elapsed time, and worker outcome.
- The same process worker now invokes `beepbeep.worker.releaseTalkTurn.printDecisionJson` for `ReleaseTalkTurn` decisions, so request and release route paths both cross the Rust-to-Unison worker boundary.
- The current worker is process-per-command with serialized execution; the remaining Stage 2 hardening is a genuinely warm stdio or Unix-socket worker pool once profiling shows process startup is material.

### Stage 3: Rust Runtime Skeleton And Relay Extraction

Owner: Rust runtime.

Goal: turn the existing relay into reusable runtime transport modules without changing client behavior.

Work:

1. Keep the current `relay` binary running as the canary.
2. Extract relay protocol/state/auth/transport modules behind library APIs.
3. Add a new runtime crate or package boundary for HTTP/WebSocket/kernel/DB work.
4. Keep relay tests green through extraction.
5. Add a local process health surface for the runtime skeleton.

First proof lane:

```bash
cd relay
cargo test -q
cargo build --release --bin relay
```

Artifact path:

- relay test output
- module/crate boundary diff
- probe output when transport behavior changes

Done condition:

- Existing QUIC datagram and TCP/TLS relay behavior remains unchanged.
- Reusable transport modules can be linked by the self-hosted runtime.
- The current canary relay remains deployable until the integrated runtime proves parity.
- Relay protocol/state modules have property or fuzz coverage for duplicate joins, stale peer removal, oversized datagrams, invalid tokens, and malformed frames.

### Stage 4: Postgres Durable Slice

Owner: Rust runtime plus Unison kernel.

Goal: implement one durable route with Rust DB effects and Unison decisions.

First route in the self-hosted lane:

```text
POST /v1/conversations/{conversationId}/talk-turns/request
POST /v1/conversations/{conversationId}/talk-turns/renew
POST /v1/conversations/{conversationId}/talk-turns/release
```

For shadow comparison, the Rust adapter may also accept the current Cloud-compatible `/v1/channels/{channelId}/begin-transmit`, `/v1/channels/{channelId}/renew-transmit`, and `/v1/channels/{channelId}/end-transmit` routes and translate them into the self-hosted Talk Turn boundary. Keep those compatibility terms at the route boundary.

Rust responsibilities:

1. Load snapshot from Postgres.
2. Call `beepbeep.talkTurn.request`.
3. Execute the returned transaction effect plan.
4. Emit post-commit websocket/APNs/diagnostic effects only after commit.
5. Persist replay facts.

First proof lane:

```bash
cargo test -q -p beepbeep-runtime request_talk_turn_postgres
```

Add a local integration lane:

```bash
docker compose -f backend/infra/self-hosted/docker-compose.yml up -d postgres redis
cargo test -q -p beepbeep-runtime --test request_talk_turn_integration
```

Artifact path:

- SQL migration files
- integration test DB dump or replay fixture
- kernel replay log

Done condition:

- Rust/Postgres grants and denies the same cases as the Unison kernel golden tests.
- DB constraints enforce the same one-current-Talk-Turn invariant as the kernel.
- EffectPlan interpreter property tests prove transaction ordering, idempotency, and post-commit effect separation.

Current implementation note:

- `just self-hosted-http-probe` now runs both the in-process route tests and a real TCP HTTP probe.
- The process-level probe opens a local listener, sends `/s/turbo/v1/health`, `/s/turbo/v1/config`, `/s/turbo/v1/auth/session`, `/s/turbo/v1/devices/register`, `/s/turbo/v1/presence/heartbeat`, `/s/turbo/v1/telemetry/events`, user lookup, presence lookup, identity resolve, direct channel, self and peer join, state/readiness, receiver-audio-readiness, beep list, native `RequestTalkTurn`, app-prefixed native `RequestTalkTurn`, native actor-owned `RenewTalkTurn`, native `ReleaseTalkTurn`, legacy `/begin-transmit`, legacy `/renew-transmit`, legacy `/end-transmit`, and bad Conversation-path requests over `TcpStream`, and writes `/tmp/turbo-self-hosted-http-probe.json`. Cutover readiness requires both the boolean projections and 25 structured route observations with method, path, status code, expected status code, semantic label, and `ok=true` for every documented route.
- The Rust HTTP route accepts both root `/v1/...` paths and app-compatible `/s/turbo/v1/...` paths so simulator scenarios can point at the self-hosted runtime with the same base URL shape as the local Unison backend.
- `just self-hosted-serve-smoke` starts an explicit in-memory HTTP/WebSocket smoke server for route and simulator harness plumbing; it is not cutover evidence for the Postgres-backed runtime.
- The Postgres/Redis-backed integration lane still requires Docker or a reachable local Postgres/Redis stack.
- `just self-hosted-preflight` validates Docker CLI availability, compose-file syntax, Docker daemon reachability, direct TCP reachability for the expected Postgres/Redis ports, and lightweight Postgres/Redis protocol probes, then writes `/tmp/turbo-self-hosted-preflight.json`.
- The preflight passes when Docker Compose can manage the services or when compatible Postgres/Redis services are already reachable at the expected local ports. Cutover readiness requires the artifact to include the step evidence for the selected substrate: Docker CLI, compose file/config, and daemon for `docker-compose`; or TCP and protocol probes for both services for `existing-services`.
- `just self-hosted-up`, `just self-hosted-down`, `just rust-runtime-integration`, and `just runtime-postgres-integration` are now stable operator recipes for the local Postgres/Redis lane.
- `PostgresDecisionCommitter::deliver_pending_post_commit_effects` now interprets committed outbox rows only after the SQL transaction has committed, decodes known kernel post-commit effects into typed Rust actions, plans concrete WebSocket/APNs/diagnostic runtime side effects, calls an explicit `PostCommitEffectSink`, and marks rows delivered only after sink success.
- The in-memory and Postgres effect interpreters now both fence `clear-talk-turn` by `talkTurnEpoch`, so stale release effects cannot clear a newer current Talk Turn in either proof lane.
- `ReleaseTalkTurnRuntime` and `SelfHostedRouteService::handle_release_talk_turn` keep the kernel-driven `clear-talk-turn` replay/outbox proof path available for corpus compatibility and stale-release effect-plan coverage.
- The live HTTP `/talk-turns/release` route now uses the actor-owned release committer: it verifies the releasing Participant/Device owns the current Talk Turn, removes only the matching epoch, commits a durable actor `Released` event, plans release WebSocket/diagnostic side effects, and exposes a native `{"status":"released"}` response without a synchronous Unison call.
- `SelfHostedRouteService::handle_renew_talk_turn` and the HTTP `/talk-turns/renew` route now renew the current Talk Turn through the Rust actor boundary, update the current lease, commit a durable actor `Renewed` event, and expose a native `{"status":"renewed"}` response without calling the Unison kernel.
- Legacy `/v1/channels/{channelId}/end-transmit` now accepts the Swift app's current `deviceId`/optional `transmitId` body, verifies that the device owns the current Talk Turn, releases the matching actor epoch, commits a durable actor `Released` event, and returns the Cloud-compatible `{"status":"stopped"}` response.
- `runtime_talk_turn_actor_operation_results` now records actor-owned renew/release operation results by route and `operationId`, including command hash, result kind, Talk Turn row, and exact actor event row ids. This makes duplicate renew/release requests replay the same committed result and makes same-operation/different-command retries fail closed, matching the idempotency contract already used by kernel replay facts.
- `just rust-runtime-integration` records preflight, compose startup, and the ignored Postgres/Redis integration test in `/tmp/turbo-rust-runtime-integration.json`; the artifact names each live proof explicitly: schema application, snapshot loading from live rows, Talk Turn DB constraints, kernel replay idempotency, post-commit outbox delivery, durable WebSocket authorization facts, and Redis owner-record CAS execution. Until the live integration test can run, those proofs are marked `blocked` with the substrate reason.

### Stage 5: Shadow Comparison

Owner: backend/platform.

Goal: compare Rust runtime decisions against current Unison Cloud behavior without serving production traffic.

Shape:

```text
probe/scenario input
  -> current Unison Cloud backend
  -> Rust self-hosted backend
  -> compare normalized response and state projection
```

First proof lane:

```bash
just route-probe
cargo test -q -p beepbeep-runtime shadow_request_talk_turn
```

Escalation condition:

- If behavior differs, classify it as intended model improvement, current Cloud bug, or Rust/kernel implementation bug before proceeding.

Artifact path:

- shadow comparison JSON
- normalized route response diffs
- replay logs
- per-iteration normalized comparison observations with route pair, verdict, Cloud outcome, and self-hosted outcome

Done condition:

- The first vertical slice has explainable parity or an explicitly accepted semantic improvement.

### Stage 6: WebSocket Signaling Single Instance

Owner: Rust runtime.

Goal: replace Cloud websocket routing in the self-hosted lane for one instance.

Rust responsibilities:

- authenticate websocket connection
- bind `deviceId -> connection`
- authorize envelope using kernel decision or cached policy
- route opaque signaling payloads
- clear connection state on disconnect
- record session epoch

First proof lane:

```bash
cargo test -q -p beepbeep-runtime websocket_single_instance
```

Broader proof:

```bash
just hosted-backend-client-probe <rust-local-base-url>
```

Artifact path:

- websocket probe JSON
- per-connection structured logs
- replay facts for authorization decisions

Done condition:

- Two local clients can connect, exchange authorized signaling, disconnect, and reconnect without stale session authority.

Current implementation note:

- `just self-hosted-websocket-probe` now exercises the in-memory signaling authority, a real TCP/WebSocket probe, and the app-compatible clustered WebSocket path. Cutover readiness requires the boolean projections plus 16 structured observations across `in-memory`, `network`, and `app-compatible-cluster` modes for initial routing, stale socket rejection, reconnect routing, real TCP/WebSocket routing, app-compatible clustered handshake, owner-routed delivery, and authorization fact recording.
- The network probe connects two clients, routes an opaque direct-QUIC offer, reconnects the target Device on a replacement socket, rejects the stale socket, and routes the next offer to the new session epoch.
- The app-compatible clustered probe opens `/s/turbo/v1/ws?deviceId=...&conversationId=...`, locally claims Conversation ownership, routes a signal from a non-owner ingress through the owner runtime, and records connection and signal authorization facts to the configured sink.
- The in-memory smoke runtime mounted by `just self-hosted-serve-smoke` also accepts the Swift app's `/s/turbo/v1/ws?deviceId=...` path, derives the Participant from `x-turbo-user-handle` or bearer auth, emits the app-compatible `status/deviceId/sessionId` acknowledgement, and routes current Swift signal envelope types such as `receiver-ready`.
- The production-shaped `beepbeep-runtime` binary now uses the same HTTP/WebSocket accept loop as the smoke runtime, so `/s/turbo/v1/ws?deviceId=...` is mounted beside the Postgres-backed HTTP routes and live `/v1/config` advertises websocket support.
- The production-shaped `beepbeep-runtime` binary records WebSocket authorization facts to Postgres in `runtime_websocket_authorization_facts`; the smoke runtime keeps the same authority with a no-op sink. Facts include connection, conversation, Participant, Device, session epoch, decision, and reason.
- `runtime/src/websocket_cluster.rs` now proves the owner-routed multi-runtime WebSocket authority in memory: non-owner connects forward to the Conversation owner runtime, messages route through the owner, no-owner/draining Conversations request reconnect, and owner transfer purges stale socket bindings.
- `AppCompatibleWebSocketHub::with_cluster_authority` wires that owner-routed authority into the real app-compatible TCP/WebSocket handshake for Conversation-bound requests carrying `conversationId` or `channelId`; the default Swift-compatible path without a Conversation remains single-instance/unbound.
- The production-shaped `beepbeep-runtime` binary can now be started with `TURBO_RUNTIME_WEBSOCKET_MODE=clustered-single-active`, `TURBO_RUNTIME_ID`, and `TURBO_RUNTIME_WEBSOCKET_OWNER_TTL_MS`; in that mode it locally claims/renews Conversation ownership before routing WebSocket connections, which covers the first sticky single-active runtime trial without enabling active-active authority.
- `OwnerRecordExchange` models the Redis/NATS-shaped owner-record boundary: lease records use stale-record rejection, drain records publish reconnect intent, delayed delivery is replayable, and WebSocket clusters can observe lease/drain records to update routing and purge stale bindings.
- Owner records now have a stable JSON wire shape (`{"kind":"lease"|"drain","lease":{...}}`) with camel-case lease fields, and `OwnerRecordWireExchange` proves stale rejection, delivery, and drain semantics after encode/decode.
- `OwnerRecordTransport` wraps the encoded exchange behind a service-client-shaped trait; `InMemoryOwnerRecordTransport` is the deterministic proof implementation, and `RedisOwnerRecordWritePlan` defines the Redis key/channel, checked JSON payload, TTL, and CAS Lua script arguments a live Redis client must use.
- The ignored Postgres/Redis integration proof executes that Redis command plan against a real service; remaining cutover hardening for this lane is enabling clustered hub mode in the production `beepbeep-runtime` process after the live substrate proof is green.

### Stage 7: Realtime Talk Turn Actor

Owner: Rust runtime plus protocol model.

Goal: move live Talk Turn grant/renew/release into a Rust Conversation actor while keeping the kernel as policy authority.

Rules:

- No synchronous Unison call per renewal.
- No DB call per audio packet.
- Actor grants only from a validated `ConversationPolicySnapshot`.
- Actor emits idempotent durable events to Postgres.
- Crash behavior is explicit: clients reconnect, rejoin, refresh, and re-request if still pressing.

First proof lane:

```bash
just protocol-model-checks
just protocol-talk-turn-actor-model-check
cargo test -q -p beepbeep-runtime talk_turn_actor
```

Required invariants:

- one runtime owner per Conversation
- at most one active Talk Turn
- stale release cannot clear newer grant
- lease expires without renewal
- policy downgrade can revoke active grant
- drain causes reconnect/rejoin, not durable channel loss

Artifact path:

- TLA+ output
- Rust actor test output
- replay events

Done condition:

- Actor model and implementation prove Talk Turn exclusivity under duplicate, stale, reconnect, and drain traces.

Current implementation note:

- `specs/tla/TurboTalkTurnActor.tla` models the self-hosted Rust actor lane for owner leases, one active Talk Turn, renewal, stale release fencing, lease expiry, policy downgrade, drain/reconnect, and participant disconnects.
- `just protocol-talk-turn-actor-model-check` validates and runs the focused model without Swift property tests.
- The model found and promoted an owner-expiry counterexample: active Talk Turns must clear when the runtime owner lease expires. The Rust actor now stores owner lease expiry, rejects grants after owner expiry, and records `OwnerExpired` when expiry clears an active turn.
- The Rust actor now has an explicit `renew_talk_turn` transition that validates owner lease, active `talkTurnEpoch`, policy, and drain state, extends the active lease without a synchronous Unison call, and records a durable `Renewed` event.
- `runtime_talk_turn_actor_events` records actor events by Conversation, owner runtime, owner epoch, and actor event id; the in-memory and Postgres committers replay the same actor event idempotently and reject conflicting replays.
- Actor renew/release operation results are separately recorded by route and `operationId`, so transport retries after a committed mutation do not extend a lease twice or fail just because a release already removed the current Talk Turn. Replays reload the exact actor event row ids stored with the operation result rather than reconstructing events by operation id.
- Actor renewal events plan a typed `WebSocketNotifyTalkTurnRenewed` side effect plus a diagnostic event, so renewal now crosses the durable event and runtime-effect boundary instead of existing only inside the actor state machine.
- Native `/v1/conversations/{conversationId}/talk-turns/renew` is actor-owned and uses the durable renewal path; the HTTP probe now exercises it between grant and release.
- Native `/v1/conversations/{conversationId}/talk-turns/release` is actor-owned and uses the durable release path; the older kernel release runtime remains as a replay/outbox compatibility proof lane.
- Legacy `/v1/channels/{channelId}/renew-transmit` adapts the Swift app's current `deviceId`/optional `transmitId` body into the same actor-owned renewal path and returns the Cloud-compatible `{"status":"transmitting"}` response.
- Legacy `/v1/channels/{channelId}/end-transmit` adapts the Swift app's current `deviceId`/optional `transmitId` body into the actor-owned release path and returns the Cloud-compatible `{"status":"stopped"}` response.
- The TLA+ actor model includes `RenewTalkTurn`; the focused model check is green with renewal, stale release, lease expiry, policy downgrade, drain/reconnect, owner expiry, and participant disconnect invariants.

### Stage 8: QUIC And Media-Aware Runtime

Owner: Rust runtime plus Swift adapters.

Goal: integrate the extracted Rust relay transport modules into the self-hosted lane without replacing the existing Direct QUIC or WebSocket fallback prematurely.

Rules:

- Backend QUIC can be a relay/control service; direct device-to-device QUIC remains opportunistic.
- No Unison call for media packets.
- Packet media remains packet media; do not hide ordered stream fallback as packet media.
- WebSocket remains fallback until physical-device proof says otherwise.
- Preserve current relay canary behavior until the integrated runtime has equivalent probe evidence.

First proof lane:

```bash
cargo test -q -p beepbeep-runtime quic_protocol
cd relay && cargo test -q
```

Broader proof:

```bash
just simulator-scenario fast_relay_active_transmit_network_migration
```

Escalate to physical devices only for real UDP/QUIC reachability, Apple PushToTalk, audio-session activation, and audible media.

Artifact path:

- QUIC protocol test logs
- simulator scenario artifacts
- physical-device diagnostics when required

Done condition:

- Integrated Rust QUIC/TCP path improves or matches existing relay/WebSocket behavior and has explicit fallback.
- The standalone relay binary can be retired only after the integrated runtime passes the same probe and physical-device relay cells.
- QUIC/TCP frame parsers and relay state transitions have fuzz or property coverage for malformed, duplicate, oversized, stale, and cross-Conversation frames.

Current implementation note:

- `runtime/src/quic_protocol.rs` now has a runtime media-frame authority and sequence ledger before relay forwarding.
- The boundary rejects malformed relay JSON, empty media identities, cross-session media frames, unauthorized senders, duplicate or stale sequence numbers, and oversized packet payloads.
- Packet media and TCP fallback sequence ledgers are kept separate so ordered fallback does not masquerade as packet media.
- `just rust-runtime-fuzz` exercises generated QUIC protocol rejection cases alongside effect, actor, owner-routing, and WebSocket cluster authority checks, and emits per-iteration observations for each runtime boundary.

### Stage 9: Horizontal Scaling

Owner: Rust runtime/platform.

Goal: safely run more than one Rust runtime instance.

Prerequisite:

- Single-instance runtime is green for durable route, websocket signaling, Talk Turn actor, and drain behavior.

Options:

| Option | Use when |
| --- | --- |
| Sticky single active instance | First production-shaped trial. |
| Active/passive | Failover is more important than scale. |
| Redis/NATS owner routing | Multiple pods must route to the Conversation owner. |
| Rust-to-Rust forwarding | One actor per Conversation with explicit owner lookup. |

Do not enable active-active Talk Turn authority until ownership is proven.

First proof lane:

```bash
cargo test -q -p beepbeep-runtime multi_node_routing
```

Artifact path:

- multi-node test logs
- owner-routing trace
- drain/reconnect replay

Done condition:

- Two clients on different pods cannot create split-brain Talk Turn ownership.
- Multi-node ownership fuzz covers duplicate routing, stale owner records, drain, reconnect, and delayed pub/sub delivery.

Current implementation note:

- `runtime/src/multi_node_routing.rs` now returns explicit route plans: handle locally, forward to the owner runtime, or require reconnect.
- Draining a runtime removes owned Conversations from routing and forces reconnect until the Conversation is reclaimed.
- Delayed owner-record delivery accepts fresh records and rejects expired or stale records that would rewind newer ownership.
- `runtime/src/websocket_cluster.rs` composes owner routing with WebSocket bindings so a non-owner ingress cannot create split-brain socket authority for a Conversation.
- `TURBO_RUNTIME_WEBSOCKET_MODE=clustered-single-active` enables the production binary's first sticky single-active cluster mode; it claims local Conversation ownership on connect with a bounded owner TTL while active-active owner exchange remains gated on the live Redis proof lane.
- `OwnerRecordExchange` covers the Redis/NATS-shaped shared owner-record contract for lease compare-and-set, delayed lease delivery, drain delivery, and observer convergence without needing a live service.
- `OwnerRecordWireExchange` covers the same contract over encoded JSON records so service-client implementations have a checked wire format.
- `OwnerRecordTransport`, `RedisOwnerRecordWritePlan`, and `RedisOwnerRecordTransport` define the live-service boundary for owner-record writes; the ignored Postgres/Redis integration lane runs the CAS Lua script against a real Redis service when the local substrate is available.
- `just rust-runtime-fuzz` covers duplicate routing, stale owner records, drain, reconnect, delayed pub/sub delivery, owner-record exchange convergence, owner-record transport encoding, owner-routed WebSocket forwarding, and stale binding purge after owner transfer in the deterministic runtime fuzz lane.

### Stage 10: Consolidated Self-Hosted Fuzz Gate

Owner: reliability/platform.

Goal: make the self-hosted lane at least as bug-finding capable as the current engine, simulator, and backend fuzz lanes.

This is a consolidation step, not a replacement of the Unison fuzzing strategy. Keep pure semantic generation and shrinking in Unison where the domain model is strongest, then reuse those corpora at the Rust boundary and in end-to-end self-hosted scenarios.

Required gates:

| Gate | Scope |
| --- | --- |
| `just kernel-fuzz` | Pure Unison kernel decision generation, replay, and shrinking. |
| `just rust-runtime-fuzz` | Rust EffectPlan interpreter, parsers, protocol frames, actor state machines. |
| `just self-hosted-scenario-fuzz-local <seed> <count>` | Rust runtime plus Postgres/Redis/NATS route, websocket, and Talk Turn interleavings. |
| `just shadow-backend-fuzz <seed> <count>` | Cloud backend vs self-hosted normalized behavior comparison. |
| `just reliability-fuzz-self-hosted-overnight <seed> <count>` | Combined kernel, Rust, and self-hosted scenario sweep. |

First proof lane:

```bash
just kernel-fuzz
just rust-runtime-fuzz
just self-hosted-scenario-fuzz-local 123 3
```

Failure loop:

1. Stop on first failure.
2. Preserve seed, minimized input, `KernelRequest`, `KernelResponse`, runtime trace, and DB snapshot when relevant.
3. Classify owner: kernel meaning, Rust effect interpreter, protocol parser, actor/concurrency, DB constraint, Redis/NATS routing, app adapter, or Apple/Device boundary.
4. Promote to the narrowest durable proof.
5. Rerun the failed lane, then the local self-hosted regression gate.

Artifact path:

- `/tmp/turbo-kernel-fuzz/`
- `/tmp/turbo-rust-runtime-fuzz/`
- `/tmp/turbo-self-hosted-fuzz/`
- `/tmp/turbo-shadow-backend-fuzz/`

Done condition:

- Kernel, Rust runtime, and self-hosted distributed fuzz all have replayable artifacts.
- A single failure can be reduced to a kernel fixture, Rust property/fuzz corpus case, or checked-in scenario.
- The overnight self-hosted sweep can run without relying on the current Unison Cloud backend except for explicit shadow comparison.

Current implementation note:

- Initial deterministic replay gates exist for `rust-runtime-fuzz`, `self-hosted-scenario-fuzz-local`, `shadow-backend-fuzz`, and `reliability-fuzz-self-hosted-overnight`.
- `self-hosted-scenario-fuzz-local` now composes the fast in-memory route/WebSocket/actor/owner-routing check with a production-shaped process lane: it starts Docker-backed Postgres/Redis, applies the runtime schema, launches the real `beepbeep-runtime` binary in clustered-single-active mode, seeds live Conversation/Participant/Device/Session/readiness rows, and drives native request/renew/release Talk Turn routes over HTTP.
- The combined scenario fuzz artifact records both `self-hosted scenario iteration ...` and `production-runtime scenario iteration ...` checks in `/tmp/turbo-self-hosted-fuzz/report.json`; cutover readiness also requires the production-shaped artifact to prove the Postgres/Redis substrate, schema application, runtime health, and a successful request/renew/release Talk Turn flow for each production iteration.
- The other first gates use deterministic in-memory route, WebSocket, actor, owner-routing, shadow, and protocol boundaries so they run without Docker.
- `rust-runtime-fuzz` now includes the owner-routed WebSocket cluster authority alongside EffectPlan interpretation, actor exclusivity, owner routing, and QUIC protocol boundaries. The artifact records all five observation kinds for every iteration, so cutover readiness rejects label-only fuzz reports.
- `reliability-fuzz-self-hosted-overnight` now carries the composed runtime and shadow observations from its child lanes; cutover readiness requires every overnight runtime iteration to include all five runtime-boundary observations and every shadow iteration to include a normalized Cloud-vs-self-hosted comparison observation.
- The owner-record exchange boundary, JSON wire format, Redis write-plan contract, live Redis CAS execution path, and production-shaped Postgres/Redis scenario artifact are modeled or integrated.
- `just self-hosted-preflight` now records whether the local Docker/Compose substrate can run that production-shaped lane before the longer integration recipe starts.

### Stage 11: Cutover Readiness

Owner: release/platform.

Goal: decide whether the self-hosted lane can replace the current Unison Cloud backend.

Required evidence:

- kernel golden tests pass
- Rust integration tests pass
- protocol model checks pass
- shadow comparison is explained
- websocket probe is green
- simulator scenario suite is green against self-hosted base URL
- physical-device cells are green for PTT/audio/QUIC/APNs boundaries
- rollback path keeps current Cloud backend usable

Done condition:

- Cutover is an operator decision with clear parity, reliability, latency, and rollback evidence.

Current implementation:

- `backend/scripts/self_hosted_cutover_readiness.py` reads the kernel, runtime, model-check, shadow, HTTP, websocket, fuzz, infrastructure, simulator, physical-device, and rollback evidence artifacts.
- `just self-hosted-cutover-readiness` writes `/tmp/turbo-self-hosted-cutover-readiness.json` and mirrors the same payload to `/tmp/turbo-self-hosted-cutover-readiness-current.json` so follow-up operator status commands do not read stale readiness state after a non-ready exit.
- `just unison-kernel-rust-runtime-audit` reads this document's command-target table, checks that every documented `just` command has a matching recipe in `justfile`, and writes `/tmp/turbo-unison-kernel-rust-runtime-audit.json`.
- The readiness gate requires the kernel corpus to contain unique Stage 1A case ids with command/snapshot/policy envelopes, expected decision kind, audit envelope, and grant/deny effect semantics; the command-target audit to prove documented `just` commands exist in `justfile`; fuzz artifacts to match their expected gate names and minimum unique contiguous iteration coverage; `rust-runtime-fuzz` to include per-iteration observations for EffectPlan interpretation, actor exclusivity, owner routing, WebSocket cluster authority, and QUIC payload boundaries; `reliability-fuzz-self-hosted-overnight` to preserve the same runtime observations plus shadow comparison observations from its composed child lanes; `self-hosted-scenario-fuzz-local` to prove deterministic in-memory iterations plus production-runtime Postgres/Redis substrate, schema, runtime health, and request/renew/release Talk Turn steps; `shadow-backend-fuzz` to include per-iteration normalized comparison observations with the legacy Cloud route, self-hosted Talk Turn route, equivalent and divergent verdict coverage, and both normalized outcomes; the HTTP probe to prove native request/renew/release, app-prefixed native request, legacy begin/renew/end, and bad-request rejection through structured route observations; and the WebSocket probe to prove in-memory routing, real TCP/WebSocket routing, reconnect session freshness, app-compatible clustered owner routing, and authorization fact recording through structured event observations.
- `just simulator-scenario-suite-self-hosted` checks self-hosted health and config semantics at `http://127.0.0.1:8091/s/turbo/v1/health` and `/v1/config`, runs the checked-in simulator scenario suite only when the runtime is reachable and reports `runtime=self-hosted`, `mode=self-hosted`, and WebSocket support, then runs strict merged diagnostics and writes `/tmp/turbo-simulator-self-hosted-suite.json`. Cutover readiness requires the artifact to include the passing self-hosted preflight, scenario runner command, stdout evidence that every checked-in `scenarios/*.json` case ran and produced a success marker, and the strict merged-diagnostics step with the generated self-hosted simulator device ids; a top-level passing status or shallow command success alone is rejected as stale evidence.
- `just cloud-rollback-probe` runs the current Cloud schema-drift guard plus a hosted backend stability probe, then writes `/tmp/turbo-cloud-rollback-probe.json`. Cutover readiness requires the schema-drift step to pass and the hosted stability artifact to include both summary and per-request result rows for health, config, auth, device registration, incoming/outgoing Beeps, heartbeat, and telemetry with zero failed or slow endpoint checks.
- `just physical-device-boundary-collect "<handles>" "<--device @handle=deviceId...>" "<--physical-device udid...>" "<--artifact path...>"` collects connected-device app diagnostics, optionally launches connected devices with a debug transport profile, optionally runs reliability intake for backend latest diagnostics, derives the physical manifest, runs the physical proof, and writes a run summary under `/tmp/turbo-physical-device-boundary-run/` by default.
- Targeted collection can encode the intended proof cell by passing `target_args="--target-cell <cell>"`, where `<cell>` is one of `foreground-ptt-audio`, `lockscreen-apns-wake`, `direct-quic-media`, or `fallback-relay-audio`. The collector records `targetCell` and `targetCellPlan` in the run summary, chooses the required transport launch profile for Direct QUIC and fallback relay cells, writes targeted manifest/proof artifacts under the run directory by default, exits successfully when the requested target cell passes even if other physical cells remain incomplete, and rejects mismatched profiles unless `--allow-profile-mismatch` is present.
- For profile-based physical cells such as Direct QUIC and fallback relay, the collector uses the profile launch itself as the launchability proof instead of doing a separate plain launch first. This avoids a redundant CoreDevice foreground launch and keeps the diagnostic window tied to the profile that the cell is proving.
- Targeted collection summaries include `targetCellProof`, a machine-readable projection of the intended proof cell's `status`, `reason`, `missingEvidence`, and `missingContext`, so a failed run identifies the next missing anchor without manually reading the full proof artifact.
- Targeted collection summaries also include `nextCommands`: a rerun command for the same target cell and a finalize command that merges passing cells from the run directory into the canonical physical proof.
- When launch profile application fails, targeted collection summaries include `launchFailures` with per-device name, UDID, reason, and message. Specific CoreDevice locked-device evidence wins over generic `run-connected` failure summaries; devices that only appear in the final command summary remain visible as `device-command-failed`.
- Targeted launch profiles are now visible in app diagnostics: app initialization records `Physical boundary launch profile` when physical-boundary transport environment variables are present, with `transport=direct-quic` or `transport=media-relay-forced`. The manifest generator accepts these anchors as transport context evidence, while media/audio cells still require their packet and playback checks.
- Targeted Direct QUIC and fallback relay collection records a current `device_app.py list --json` preflight before launch and requires two visible paired physical iOS devices. A stale non-connected tunnel state is recorded as a warning because `devicectl` may acquire the tunnel during a later command; fewer than two visible paired devices remains an operator blocker. If preflight blocks collection, the collector records `currentDevicePreflight` and `operatorBlockers`, skips the target launch/interaction window unless `--continue-after-launch-failure` is present, still writes manifest/proof/summary artifacts, and leaves the proof failed. If `devicectl` later rejects a launch, `device_app.py run-connected --continue-on-device-error` still attempts the remaining devices, the collector records per-device launch failures, skips the timed interaction window unless `--continue-after-launch-failure` is present, still collects diagnostics when enabled, and leaves the proof failed.
- Targeted Direct QUIC and fallback relay collection no longer runs a separate plain `launch-connected` preflight before the profile launch. A plain launch can consume the same CoreDevice foreground path without proving the intended transport environment, so profile application through `device_app.py run-connected` is the launchability proof for these cells. If the profile launch classifies a device as `locked`, `device-disconnected`, or `device-unavailable`, the collector records per-device launch failures, skips the timed interaction window unless `--continue-after-launch-failure` is present, still collects diagnostics when enabled, and leaves the target proof failed.
- Physical launch profiles are explicit evidence setup, not proof substitution: `launch_profile=direct-quic` disables relay-only, enables Direct QUIC auto-upgrade, and disables forced media relay before collection; `launch_profile=fallback-relay` disables Direct QUIC auto-upgrade and forces media relay; lock-screen APNs wake still requires a real locked/background receiver and PushToTalk APNs delivery.
- Incoming PushToTalk callbacks now record lock-screen proof metadata on the `Incoming PTT push received` line: `applicationState`, `receiverState`, `lockState`, `protectedDataAvailable`, and `protectedDataState`. The lock-screen APNs cell accepts `receiverState=background`, `lockState=locked`, or `protectedDataState=protected-data-will-become-unavailable` only when the same physical artifact also proves the wake activation and playback checks.
- Lock-screen wake proof accepts the current receiver wake-timing diagnostics as activation/playback evidence: `PTT audio session activated` in background with a pending wake channel, `Wake receive timing ... stage=system-audio-activation-observed`, `stage=first-playback-buffer-scheduled`, `stage=playback-node-started`, and first playback ACKs. These anchors still have to be inside the collection evidence window for the target cell to pass.
- Wake evidence collection can include the APNs sender in the same artifact lane by passing `wake_args="--send-wake-apns --wake-channel-id <channel> --wake-handle <sender>"`; this requires the receiver to already be locked/backgrounded and APNs credentials to be present in the environment. `--target-cell lockscreen-apns-wake` requires this sender unless `--allow-manual-wake` is present for an externally triggered wake.
- The APNs sender supports `--check-credentials` and `--print-only`; `just ptt-apns-print-only <channel-id> ... <sender-handle>` dry-runs the backend PushToTalk target lookup before the receiver is locked or a real APNs push is sent. Lock-screen wake collection records `apnsCredentialPreflight` before attempting the wake send. Missing APNs signing inputs become operator blockers and skip the wake send step, so credential failures are separated from receiver lock/background and playback proof failures. Backend push-target lookup failures are emitted as structured JSON with HTTP status/body when available, and physical status converts known backend failures such as `not-channel-member` or missing push targets into `wakeSendDiagnosis`, so target lookup, credential, receiver state, and playback failures remain distinct in the readiness artifacts.
- `just physical-device-boundary-merge "<manifest...>"` merges run-local physical manifests into `/tmp/turbo-physical-device-boundaries-manifest.json` cell-by-cell. A cell is promoted only if `scripts/physical_device_boundary_proof.py` validates that cell, so separate foreground, fallback, Direct QUIC, and lock-screen runs can compose without weakening the cutover gate. The merged manifest preserves per-source `evidenceSince` windows, and promoted cells carry their source evidence window.
- `just physical-device-boundary-finalize "<run-dir-or-summary-or-manifest...>"` resolves physical collection run directories, `physical-device-boundary-collect.json` summaries, and manifest paths, skips known optional physical run slots that have not been collected yet, merges the accepted cells into the canonical manifest, runs the canonical proof, and writes `/tmp/turbo-physical-device-boundary-finalize.json` with `skippedMissingInputs`.
- `just physical-device-boundary-status` combines the current cutover readiness artifact with recent target-cell collection summaries, reports missing physical cells from structured `physicalFinalizeSummary.failedCells` when present, exposes the compact `physicalFinalizeSummary` and `physicalEvidenceWindow` at the top level for operator queries, carries each structured finalize cell failure into `missingCellPlans` and relevant `priorityActions`, carries target-cell proof gaps, backfills old launch failures from saved launch steps, attaches per-device launch-failure remediation for classified reasons such as locked devices and CoreDevice disconnects, records a current connected-device preflight from `scripts/device_app.py list --json`, records an advisory CoreDevice reachability probe from `scripts/device_app.py lock-state-connected --json`, records current app launchability from `/tmp/turbo-device-launch-connected-current.json` when present, carries the structured `sendWakeApnsResult` from the lock-screen wake sender step, includes a `wakeTargetPreflightCommand` dry-run for the lock-screen cell, emits `missingCellPlans` with per-cell operator requirements and next commands even when no target run exists yet, emits top-level `priorityActions` ordered from device/preflight fixes to current launchability failures, target-run launch failures, and missing cell collection, includes `just device-launch-connected-json` plus `/tmp/turbo-device-launch-connected-current.json` as a cheap machine-readable verification lane for locked-device launch failures, exposes `commandReady` / `commandReadinessStatus` so paired-device visibility is not confused with current CoreDevice command readiness, flags stale target-run launch failures when the fresh launchability probe reports a different current failure, compacts raw step stdout/stderr into byte counts plus diagnostic lines so the status artifact stays scan-friendly, and writes `/tmp/turbo-physical-device-boundary-status.json`. The lock-state probe reports `passcodeRequired` and `unlockedSinceBoot` when available, but remains advisory because current foreground-launch unlock is still proven by launch diagnostics; the launchability probe proves only that the already-installed app can be foreground-launched, not that any physical boundary cell passed.
- `just physical-device-boundary-manifest "<artifact...>" "--device <sender> --device <receiver>"` scans copied or merged physical-device diagnostics and writes `/tmp/turbo-physical-device-boundaries-manifest.json`; when `devices` is omitted, merged diagnostics `reports[].deviceId` values are used when present.
- `just physical-device-boundary-proof` validates a physical-run manifest for foreground PTT/audio, lock-screen APNs wake, Direct QUIC media, and fallback relay audio, then writes `/tmp/turbo-physical-device-boundaries.json` with the manifest evidence window and source evidence windows.
- The readiness command is a gate: it exits nonzero while required cutover evidence is missing or failed, sets `ready` and `ok` to the same machine-readable cutover predicate, and lists the blocking evidence with remediations.
- When physical-device proof is blocking readiness, `just self-hosted-cutover-readiness` includes `operatorStatusArtifact`, `physicalFinalizeSummary`, plus `nextCommands` for inspecting the enriched physical-device status, collecting the failed cells: targeted Direct QUIC, lock-screen APNs wake, fallback relay, foreground PTT, and the standard canonical finalize command over all physical run slots. The finalize summary carries resolved manifests, skipped missing optional run slots, and proof cell summaries.
- When the enriched physical-device status includes `/tmp/turbo-device-launch-connected-current.json`, `just self-hosted-cutover-readiness` also carries a compact `launchabilitySummary` and `physicalPriorityActions` under the physical-device blocking evidence, preserving canonical `finalizeFailure` reasons from the status artifact, and offers `verify-device-launchability` before the Direct QUIC collection command.
- The physical-device boundary proof rejects placeholder device ids, placeholder artifact paths, missing artifacts, duplicate/single-device evidence, cells that omit required checks, and required checks without evidence anchors present in the listed artifacts; readiness reports the failed cell names and reasons.
- Transport-specific physical cells also require context anchors: Direct QUIC media must prove active Direct QUIC run configuration, fallback relay must prove relay/fallback run configuration, and lock-screen wake must prove the receiver entered background or locked state. This prevents stale mixed-mode diagnostics from satisfying the wrong physical cell.
- Fresh physical collection passes the collection start time into the manifest generator as `evidenceSince`; timestamped diagnostic lines before that instant are excluded from evidence matching. Merge, proof, finalize, and readiness artifacts carry the evidence window forward so any future pass can be audited against the diagnostic interval it actually judged. Reprocessing old artifacts can omit `--since`, but cutover collection uses a fresh evidence window so cumulative device logs cannot satisfy a new run from stale lines.
- The manifest generator marks a cell `pass` only when all required checks and context requirements have anchors present in the supplied artifacts and at least two distinct physical devices are known; incomplete cells remain `pending` so `just physical-device-boundary-proof` and cutover readiness continue to fail.
- The live Postgres/Redis integration proof slot is produced by `just rust-runtime-integration` at `/tmp/turbo-rust-runtime-integration.json`; it now records self-hosted preflight, compose/existing-service startup, Postgres and Redis TCP readiness, and the ignored Rust integration test command. That integration test proves schema application, snapshot loading from live rows, Talk Turn DB constraints, kernel replay idempotency, post-commit outbox rows, post-commit delivery marking, durable WebSocket authorization facts, and Redis owner-record CAS execution. Readiness requires the live substrate steps, both service checks, the exact `request_talk_turn_integration --ignored` command, and each named proof to pass; a top-level passing status or named-proof list alone is rejected as stale or shallow evidence.
- The Talk Turn actor model proof slot is produced by `just protocol-talk-turn-actor-model-check` at `/tmp/turbo-protocol-talk-turn-actor-model-check/protocol-model-checks.json`. Readiness requires the `TurboTalkTurnActor.tla` / `.cfg` pair, the full required invariant set, zero missing definitions, a passing TLC step, and a nonzero state-space summary; a top-level passing status alone is rejected as stale or shallow evidence.
- The Cloud rollback proof slot is produced by `just cloud-rollback-probe` at `/tmp/turbo-cloud-rollback-probe.json`.
- The physical-device proof slot is produced by `just physical-device-boundary-proof` at `/tmp/turbo-physical-device-boundaries.json`.
- The remaining simulator proof lane has an explicit artifact slot: `/tmp/turbo-simulator-self-hosted-suite.json`.

## Command Targets To Add

These commands do not need to exist before Stage 1, but the plan should converge on stable recipes:

| Command | Purpose |
| --- | --- |
| `just kernel-test` | Run pure Unison kernel tests. |
| `just kernel-fuzz` | Generate, replay, and shrink pure Unison kernel decision cases. |
| `just rust-runtime-test` | Run Rust runtime unit tests. |
| `just rust-runtime-fuzz` | Fuzz Rust effect interpretation, protocol frames, parsers, and actor state machines. |
| `just rust-runtime-integration` | Run Rust runtime against local Postgres/Redis. |
| `just self-hosted-preflight` | Check Docker, Compose config, and daemon readiness for local Postgres/Redis. |
| `just self-hosted-up` | Start local self-hosted infra. |
| `just self-hosted-route-probe` | Probe Rust self-hosted route surface. |
| `just self-hosted-serve <bind> <websocket_mode> <runtime_id> <owner_ttl_ms>` | Start the production-shaped runtime; `websocket_mode=clustered-single-active` enables the sticky single-active WebSocket authority. |
| `just self-hosted-serve-smoke` | Start the explicit in-memory smoke runtime for harness plumbing only. |
| `just self-hosted-websocket-probe` | Probe Rust websocket lane. |
| `just simulator-scenario-suite-self-hosted` | Run the simulator scenario suite against the self-hosted runtime and emit cutover evidence. |
| `just self-hosted-scenario-fuzz-local <seed> <count>` | Fuzz local Rust runtime, storage, routing, websocket, and Talk Turn interleavings; emits both deterministic in-memory and production-runtime Postgres/Redis checks. |
| `just shadow-backend-compare` | Compare Cloud backend and Rust runtime outputs. |
| `just shadow-backend-fuzz <seed> <count>` | Fuzz Cloud-vs-self-hosted semantic comparison cases. |
| `just reliability-fuzz-self-hosted-overnight <seed> <count>` | Run the combined long self-hosted reliability sweep. |
| `just self-hosted-cutover-readiness` | Summarize required cutover evidence and fail until all required proof artifacts are present and passing. |
| `just unison-kernel-rust-runtime-audit` | Verify that this document's `just` command table is backed by actual recipes in `justfile`. |
| `just kernel-compile` | Compile Unison kernel worker entrypoints into `.uc` artifacts for VM packaging. |
| `just gce-self-hosted-deploy-dry-run` | Render the Compute Engine VM deployment plan without copying or changing the VM. |
| `just gce-self-hosted-deploy` | Deploy Postgres, Redis, and the Rust runtime to the Compute Engine VM through Docker Compose. |
| `just gce-self-hosted-deploy-relay` | Deploy the same VM stack and let Docker Compose own the relay profile on TCP/UDP `443`; use only after the current relay service is intentionally drained. |
| `just cloud-rollback-probe` | Record schema-drift and hosted backend stability evidence for rollback readiness. |
| `just ptt-apns-print-only <channel_id> <base> <handle> <bundle_id> <insecure>` | Dry-run PushToTalk APNs wake target lookup without sending APNs, so live channel id and sender membership can be verified before the lock-screen cell. |
| `just device-launch-connected <bundle_id> <json>` | Launch the already-installed app on every paired physical iOS device and report all per-device launch failures without rebuilding; use `json="--json"` for machine-readable launchability evidence. |
| `just device-launch-connected-json <output> <bundle_id>` | Write machine-readable launchability evidence for every paired physical iOS device, defaulting to `/tmp/turbo-device-launch-connected-current.json`. |
| `just device-lock-state <device> <json>` | Probe `devicectl device info lockState` for one paired physical device; use `json="--json"` for machine-readable output. |
| `just device-lock-state-connected <json>` | Probe advisory CoreDevice lock-state reachability for every paired physical iOS device; use `json="--json"` for machine-readable output. |
| `just physical-device-boundary-collect <handles> <devices> <physical_devices> <artifacts> <output_dir> <insecure> <launch_profile> <wake_args> <wait> <target_args>` | Collect physical-device diagnostics, optionally apply a debug launch profile or APNs wake sender, derive the manifest, and run the proof in one repeatable lane. `target_args="--target-cell direct-quic-media"` records and validates cell intent, and the command exits successfully when that target cell passes. |
| `just physical-device-boundary-merge <manifests>` | Merge separately collected physical-device cell manifests into the canonical manifest, promoting only cells that pass the validator. |
| `just physical-device-boundary-finalize <inputs>` | Resolve physical run directories, collection summaries, and manifests; merge accepted cells; run the canonical proof; write the finalize summary. |
| `just physical-device-boundary-status <readiness> <runs> <output>` | Combine readiness blockers with recent target-cell run summaries into one operator status artifact. |
| `just physical-device-boundary-manifest <artifacts> <devices>` | Generate the physical-device boundary manifest from copied or merged diagnostics artifacts. |
| `just physical-device-boundary-proof` | Validate physical-device PTT/audio/QUIC/APNs evidence for cutover readiness. |

## Design Defaults

- Prove one vertical slice before broad porting.
- Prefer correctness and replayability over early horizontal scaling.
- Keep current Cloud backend untouched until self-hosted parity is measurable.
- Keep all live media packet flow in Rust/Swift, never Unison.
- Encode distributed safety with epochs, sequence numbers, idempotency keys, and DB constraints.
- Make every kernel decision replayable from logged request/response facts.
- Treat Rust as an effect interpreter, not the owner of domain meaning.
