# AWS Plan

Status: proposed architecture plan.
Scope: AWS relay migration, Unison BYOC staging, and later Rust/QUIC live control.

Related:

- [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md): ownership, invariant, proof, and escalation model.
- [`TOOLING.md`](/Users/mau/Development/bb/TOOLING.md): exact local, deploy, probe, scenario, and reliability commands.
- [`BACKEND.md`](/Users/mau/Development/bb/docs/backend/BACKEND.md): backend ownership and Unison Cloud rules.
- [`Server/backend_architecture.md`](/Users/mau/Development/bb/Server/backend_architecture.md): current backend/control-plane reference.
- [`ENGINE.md`](/Users/mau/Development/bb/ENGINE.md): engine boundary and transmit startup contract.
- [`relay/README.md`](/Users/mau/Development/bb/README.md): current Rust media relay.
- [`TLA_PLUS.md`](/Users/mau/Development/bb/docs/reliability/TLA_PLUS.md): protocol modeling lane for ownership/reconnect changes.

## Decision

Move to AWS in layers:

1. Move the existing Rust media relay from GCP to AWS without changing product semantics.
2. Harden relay identity, health, metrics, deployment, and token issuance.
3. Stand up Unison BYOC on AWS as a no-behavior-change backend staging lane.
4. Measure press-to-grant and media startup latency before introducing Rust live control.
5. Prototype Rust/QUIC live Talk Turn control only after channel ownership is modeled and proven.

Do not combine relay migration, Unison BYOC, and Rust live-control authority in one release.

## Current Architecture Facts

| Area | Current owner | Current shape |
| --- | --- | --- |
| Durable users/devices/channels/membership/readiness/wake targeting | Unison backend | `bb/main`, route/store/domain namespaces |
| Active Talk Turn transmit lease | Unison backend | `turbo.store.runtime.beginTransmit` and related renew/end paths |
| Local Conversation, Connection, media, PTT, and transport truth | `TurboEngine` plus Swift adapters | `Packages/TurboEngine`, `Turbo/` |
| Media relay | Rust `relay/` service | QUIC datagram packet media over UDP `443`, TCP/TLS ordered fallback over TCP `443` |
| Relay hosting | GCP VM canary | `relay.beepbeep.to -> 34.65.146.215`, DNS-only in Cloudflare |
| Relay app config | Swift debug/default config | `TURBO_MEDIA_RELAY_*` env/defaults, default host `relay.beepbeep.to` |

The existing relay is media-plane only. It validates a shared canary token, joins two device IDs into an in-memory session, and forwards encrypted packet or ordered fallback audio plus non-authoritative peer hint frames.

The proposed Rust/QUIC live control plane is a different authority class. It would move the active Talk Turn decision out of the current Unison hot path. Treat that as a separate distributed protocol change, not as a relay refactor.

## Non-Negotiable Constraints

- Unison remains durable master for users, devices, channels, membership, roles, policy, wake target eligibility, and audit/control history.
- Backend/shared truth must not be patched only in Swift.
- No database, Unison route, DynamoDB, Redis, or external coordinator should sit in the button-press live-control hot path unless measurements prove the simpler design is insufficient.
- A multi-instance Rust service must have exactly one live owner per channel before it can grant Talk Turns.
- If two clients can land on two different Rust instances for the same channel, Rust cannot be the active Talk Turn authority yet.
- Current Talk Turn/current speaker state may reset on Rust crash only if clients can reconnect, rejoin intended channels, refresh channel state, and re-request Talk Turn when still pressing.
- Media relay packet lanes must remain packet lanes. Do not silently degrade QUIC datagram audio into ordered QUIC stream audio.
- Physical-device proof is only required for Apple PushToTalk, audio-session activation, hardware capture/playback, background/lock-screen, and APNs receipt.

## Ownership Target

| Fact | Durable owner | Live owner | Crash behavior |
| --- | --- | --- | --- |
| User/device/channel/membership | Unison BYOC or Unison Cloud | None | Preserved |
| Policy snapshot/session authority | Unison | Rust cache after validation | Re-fetch or reject |
| Active media relay session | None or Unison-issued token metadata | Rust relay instance memory | Rejoin |
| Active Talk Turn grant, later phase | Unison policy plus Rust live actor | One Rust channel owner | Reset or re-request after reconnect |
| Control/audit events | Unison | Rust emits async idempotent events | Replay/reconcile from delivered events |
| Client intended channels/press state | Client | Client | Client reconnects and replays intent |

## Phase 1: AWS Relay Parity

Owner: media relay infrastructure.

Goal: run the existing relay semantics on AWS without changing app/backend behavior.

First proof lane:

```bash
cd relay
cargo test -q
```

AWS shape:

| Component | Recommendation |
| --- | --- |
| Compute | Start with one EC2 instance or one ECS/EKS task behind a stable target. |
| Load balancing | Use Network Load Balancer only after QUIC target behavior is proven. |
| Ports | UDP `443` for QUIC/datagrams, TCP `443` for TCP/TLS fallback. |
| DNS | Keep `relay.beepbeep.to`; move the Cloudflare DNS-only A/ALIAS target during cutover. |
| TLS | Use public certificate for `relay.beepbeep.to`; keep private key out of repo. |
| State | In-memory sessions only for parity. |

Important risk: the current relay stores sessions in one process. If two devices in one relay session land on different relay instances, peer lookup fails. For parity, use one active relay target or explicit active/passive. Multi-target relay requires session-owner routing or sticky rendezvous.

Required relay improvements before cutover:

| Gap | Required change | Done condition |
| --- | --- | --- |
| Health | Add `/healthz` and `/readyz` on a small HTTP admin listener or equivalent AWS health surface. | Target health reflects listener readiness and certificate/config load. |
| Metrics | Export session count, stream joins, datagram joins, peer-unavailable count, packet drops, queue drops, and send failures. | CloudWatch or telemetry dashboard can show packet relay health. |
| Deployment | Add IaC or checked-in deploy runbook for AWS resources. | A fresh relay can be recreated without manual console state. |
| Config | Keep `TURBO_RELAY_*` documented for AWS. | Runtime config path and secret source are explicit. |
| Cutover | Add rollback DNS/runbook. | GCP relay can be restored or AWS target drained without app changes. |

Verification:

```bash
cd relay
cargo test -q

just direct-quic-provisioning-probe
just simulator-scenario fast_relay_idle_network_migration
just simulator-scenario fast_relay_active_transmit_network_migration
```

Escalate to physical devices only to prove real packet relay reachability and audible media over the AWS path.

Artifacts:

- relay build logs
- AWS target health evidence
- relay metrics snapshot
- scenario artifacts under `/tmp/turbo-debug/` or `/tmp/turbo-scenario-fuzz/`
- physical-device diagnostics only when needed

Done condition:

- AWS relay passes the same packet/TCP fallback behavior as GCP.
- `relay.beepbeep.to` points to AWS.
- Fast Relay canary is green.
- Rollback path is documented and tested.

## Phase 2: Relay Hardening

Owner: backend plus relay boundary.

Goal: make the relay production-shaped without moving control-plane authority.

Required changes:

| Area | Change |
| --- | --- |
| Relay auth | Replace empty/shared canary token with Unison-issued per-session relay token. |
| Token scope | Token binds `channelId`, `sessionId`, `localDeviceId`, `peerDeviceId`, expiry, and intended relay host. |
| App config | Move from debug-only defaults toward backend-provided relay endpoint/token. |
| Diagnostics | Record relay endpoint, token expiry class, connect mode, datagram ack, fallback reason, and peer-unavailable events. |
| Backend routes | Add or extend a route that returns relay configuration only after membership/readiness authorization. |

Do not let the relay decide membership, roles, wake eligibility, or active Talk Turn authority in this phase.

First proof lane:

```bash
just route-probe-local
just swift-test-target mediaRelayDebugOverrideDefaultsToPort443
```

Add focused tests for any new token or route shape. Use local Unison through `just serve-local` for backend route semantics.

Escalation condition:

- Use simulator scenarios when app/backend endpoint discovery changes actual connection behavior.
- Use physical devices only when Network.framework or real UDP reachability is the remaining unknown.

Done condition:

- Relay token is non-empty, short-lived, channel-scoped, and backend-issued.
- App no longer needs diagnostics toggles for normal relay canary selection.
- Unauthorized devices cannot join a relay session with only guessed IDs.

## Phase 3: Unison BYOC On AWS

Owner: backend/platform.

Goal: run the existing Unison backend in AWS BYOC as a staging lane before any Rust control-plane move.

Approach:

1. Deploy Unison BYOC on AWS.
2. Keep the same backend service semantics.
3. Use a separate BYOC base URL for probes and simulator scenarios.
4. Do not change persisted shapes without the normal migration workflow.
5. Compare hosted Unison Cloud and BYOC route latency, websocket stability, and synthetic conversation SLOs.

AWS expectations from Unison BYOC references:

| Area | Expectation |
| --- | --- |
| Runtime | Unison BYOC runs Unison Cloud in the operator's infrastructure. |
| Containers | BYOC uses containerized application services. |
| Storage | Transactional Cloud storage maps to AWS infrastructure such as DynamoDB. |
| Networking | Keep a production-like HTTPS/WebSocket route surface for Turbo probes. |

First proof lane:

```bash
just backend-schema-drift-test
just route-probe-local <byoc-base-url>
just backend-stability-probe <byoc-base-url>
just websocket-stability-probe <byoc-base-url>
just postdeploy-check <byoc-base-url>
```

Then run the relevant simulator lane:

```bash
just simulator-scenario-suite-local
```

Use the BYOC base URL through the scenario runtime config or runner flags when available.

Escalation condition:

- If raw route probes fail, fix BYOC backend/runtime/deploy first.
- If probes pass but simulator scenarios fail, inspect merged diagnostics before changing app logic.
- Do not use production cutover as the first BYOC proof.

Artifacts:

- BYOC deploy artifact
- `postdeploy-check.json`
- `synthetic-conversation-probe.json`
- `slo-dashboard.json`
- websocket/backend stability probe JSON
- merged diagnostics from scenario runs

Done condition:

- BYOC can run the current backend route and websocket surface.
- Schema drift guard is green.
- Synthetic conversation canary is green.
- Local or BYOC simulator scenarios are green for the selected confidence level.

## Phase 4: Measure Before Rust Live Control

Owner: backend/app diagnostics.

Goal: prove whether Rust live control is necessary after AWS relay plus BYOC colocation.

Add or confirm timing markers for:

| Marker | Owner |
| --- | --- |
| local press began | Swift/PTT adapter |
| backend begin-transmit request sent | Swift backend client |
| target resolution started/finished | Unison route diagnostics |
| `runtime.beginTransmit` transaction started/finished | Unison store diagnostics |
| response received by app | Swift backend client |
| Apple system transmit began | Swift/PTT adapter |
| audio session activated | Swift/audio adapter |
| first outbound audio frame sent | Swift media adapter |
| receiver prepare/wake signal delivered | backend/app diagnostics |

First proof lane:

```bash
just synthetic-conversation-probe
just slo-dashboard /tmp/turbo-synthetic-conversation-probe/synthetic-conversation-probe.json
just diagnostics-merge-pair
```

Decision rule:

| Observation | Action |
| --- | --- |
| BYOC removes most press-to-grant latency | Keep Unison as active transmit owner for now. |
| Unison transaction/route remains the dominant button-press cost | Prototype Rust live Talk Turn control. |
| Apple/PTT/audio activation dominates | Do not move backend authority; optimize app/Apple boundary. |
| Media path dominates after grant | Focus relay/direct media path, not live control. |

Done condition:

- The latency budget names the dominant owner.
- Rust live control is justified by measured button-press control latency, not architectural preference.

## Phase 5: Rust/QUIC Live Talk Turn Control

Owner: distributed protocol.

Goal: introduce a Rust live-control service that can grant/deny Talk Turns without synchronously round-tripping through Unison on every press.

Target shape:

```text
Swift clients
  -> QUIC over UDP/443
  -> AWS NLB or direct endpoint
  -> Rust live-control service
  -> async idempotent events to Unison BYOC/Cloud
```

Unison owns durable policy and emits signed/expiring session or policy snapshots. Rust owns live channel actors only after it validates the snapshot.

### Required Model Before Code

Add or extend a TLA+ model for:

- one live owner per channel
- reconnect/rejoin after Rust crash
- duplicated `RequestTalkTurn`
- stale `ReleaseTalkTurn`
- channel-owner migration or drain
- policy version change while a Talk Turn is active
- async event replay into Unison

First proof lane:

```bash
just protocol-model-checks
```

Add Rust/Swift/Unison tests only after the ownership model has a named invariant set.

### Channel Ownership Options

| Option | Pros | Cons | Use when |
| --- | --- | --- | --- |
| Single active Rust control instance | Simplest and safest v1 | Limited availability/scaling | First prototype |
| Active/passive Rust control | Simple failover model | Reconnect reset on failover | Early production trial |
| Unison-assigned channel owner | Durable owner decision remains in Unison | Requires owner lookup and migration handling | Multi-instance Rust without Redis |
| Non-owner forwarding | Keeps one actor per channel | Adds Rust-to-Rust path | Multi-instance after ownership proof |
| Redis/Valkey coordinator | Familiar distributed coordination | Adds hot-path dependency | Only after evidence rejects simpler models |

Do not run active-active Rust Talk Turn authority without one of these owner mechanisms.

### Protocol Shape

Use domain terms aligned to Turbo:

| Message | Meaning |
| --- | --- |
| `ClientHello` | Client identifies app/device/protocol version. |
| `SessionAccepted` | Rust accepts a Unison-authorized session snapshot. |
| `ResumeSession` | Client reconnects with resume token and last seen channel sequence. |
| `JoinChannel` | Client declares intended live channel. |
| `ChannelState` | Rust returns current live channel actor view. |
| `RequestTalkTurn` | Client asks to speak for a channel. |
| `TalkTurnGranted` | Rust grants a bounded live lease. |
| `TalkTurnDenied` | Rust denies with typed reason. |
| `ReleaseTalkTurn` | Client releases the current live lease. |
| `TalkTurnRevoked` | Rust revokes due to expiry, disconnect, drain, policy change, or preemption. |
| `ServerDraining` | Client should reconnect and rejoin elsewhere. |
| `PolicyUpdated` | Rust applied a newer Unison policy snapshot. |

Every state-changing message must include:

- `requestId`
- `sessionId`
- `channelId`
- `deviceId`
- `policyVersion`
- `channelSeq`
- `talkTurnEpoch`

### Rust Service Invariants

| Invariant | Detector |
| --- | --- |
| One channel has one live owner. | Rust actor registry plus protocol model. |
| At most one active Talk Turn per channel. | Rust channel actor. |
| Talk Turn grant requires valid membership/policy snapshot. | Rust snapshot validator. |
| Grant lease expires without client renewal. | Rust actor timer. |
| Stale release cannot clear newer grant. | `talkTurnEpoch` check. |
| Policy downgrade can revoke active grant. | policy update handler. |
| Async Unison event sync is idempotent. | Unison event ingest route/store. |
| Draining causes reconnect/rejoin, not durable room loss. | Rust drain test plus Swift reconnect test. |

### Swift Integration

Swift must treat Rust control as an adapter behind the existing engine contract:

- `TurboEngine` still requires live Talk Turn lease evidence before capture.
- Apple PushToTalk and AVAudio activation gates remain unchanged.
- If Rust control disconnects, client projects reconnecting/degraded state, rejoins intended channels, refreshes `ChannelState`, and re-requests if the user is still pressing.
- HTTP/WebSocket begin-transmit remains fallback until Rust control proves parity.

First proof lane:

```bash
just engine-test
just swift-test-target <focused-rust-control-adapter-test>
```

Escalate to simulator scenarios only after engine and adapter tests prove local behavior.

### Unison Integration

Unison needs explicit surfaces for:

- issue/validate Rust session authority token
- produce policy snapshot
- ingest idempotent live-control events
- expose recent control events for diagnostics
- reconcile Rust event history with durable channel/user/device truth

Do not write current speaker/Talk Turn as durable source-of-truth unless the design intentionally changes the crash behavior. For the proposed v1, current Talk Turn resets on Rust crash.

### Acceptance

Rust live control is acceptable when:

- `RequestTalkTurn -> TalkTurnGranted/Denied` does not synchronously call Unison.
- A Rust crash causes reconnect/rejoin and optional re-request, not durable channel loss.
- At most one Talk Turn can be active per channel in the protocol model and implementation tests.
- Unison receives duplicate control events safely.
- Swift never starts capture without Rust/Unison live lease evidence plus Apple system transmit and audio activation.
- Drain behaves like planned reconnect, not data loss.

## AWS QUIC Notes

AWS Network Load Balancer supports QUIC/TCP_QUIC target group behavior for UDP `443` and TCP/UDP `443` listener shapes. QUIC load balancing depends on Connection IDs and Server IDs.

Before using multiple QUIC relay or control targets:

1. Confirm the chosen Rust QUIC stack can set AWS-compatible Connection ID Server IDs.
2. Assign each target a unique immutable 8-byte server ID.
3. Prove reconnect and target replacement with active clients.
4. Monitor unknown Server ID behavior.

Evaluate `s2n-quic` before replacing `quinn` for NLB-targeted multi-instance QUIC. The current relay uses `quinn`; that is fine for single-target parity, but multi-target NLB routing must be proven.

## Proof Ladder

| Phase | First proof | Broader proof | Stop when |
| --- | --- | --- | --- |
| AWS relay parity | `cargo test -q` in `relay/` | Fast Relay simulator scenarios, physical relay smoke | AWS behaves like GCP relay |
| Relay hardening | focused Swift/backend tests | route probe plus simulator scenario | token/endpoint route is authorized and app connects |
| Unison BYOC | schema drift, route probe, stability probes | postdeploy check and simulator suite | BYOC matches current backend behavior |
| Latency measurement | synthetic probe and merged diagnostics | SLO dashboard across hosted/BYOC | dominant owner is known |
| Rust live control | TLA+ model | Rust unit tests, Swift adapter tests, scenarios | ownership and reconnect invariants are green |

## References

- AWS NLB overview: <https://docs.aws.amazon.com/elasticloadbalancing/latest/network/introduction.html>
- AWS NLB listeners: <https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-listeners.html>
- AWS target registration and QUIC Server IDs: <https://docs.aws.amazon.com/elasticloadbalancing/latest/network/target-group-register-targets.html>
- AWS QUIC NLB announcement: <https://aws.amazon.com/blogs/networking-and-content-delivery/introducing-quic-protocol-support-for-network-load-balancer-accelerating-mobile-first-applications/>
- `s2n-quic` server builder docs: <https://docs.rs/s2n-quic/latest/s2n_quic/server/struct.Builder.html>
- Unison BYOC: <https://www.unison.cloud/byoc/>
- Unison BYOC announcement: <https://www.unison-lang.org/blog/cloud-byoc/>
