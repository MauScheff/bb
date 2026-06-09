# Beep Beep Backend Architecture

Status: active backend architecture.

## Decision

The Beep Beep backend is the canonical control plane.

```text
iOS client
  -> Beep Beep Rust runtime
       HTTP / runtime control / Postgres / Redis / APNs handoff / QUIC and relay integration
       |
       -> Unison kernel under beepbeep.*
            pure command decisions, snapshots, policy, effect plans, corpus, worker entrypoints
```

Canonical hosted production endpoints:

```text
API/control plane: https://api.beepbeep.to
media relay:       relay.beepbeep.to:443
```

These endpoints are one backend system with separate network roles. The API VM
owns nginx/HTTPS on TCP `443`. The relay VM owns QUIC packet media on UDP `443`
and TCP/TLS fallback on TCP `443`.

## Ownership

| Owner | Responsibility |
| --- | --- |
| Rust runtime | effects, storage transactions, routing, authoritative control, APNs integration, QUIC/relay process boundaries, deploy packaging |
| Unison kernel | pure domain meaning, Talk Turn decisions, snapshots, policy, effect plans, corpus fixtures, replay |
| iOS app | client projection, Apple PushToTalk, audio session, capture/playback, UI |
| Archive | old Unison Cloud backend reference only |

Rust may call the kernel once per semantic command. It must not call Unison per audio packet, heartbeat, persistent-control ping, or QUIC datagram.

## Transport Classes

| Class | Legal lanes | Rule |
| --- | --- | --- |
| Authoritative control | runtime QUIC control, runtime TLS control, or runtime HTTP recovery | Commands are idempotent and generation-fenced. |
| Bootstrap/recovery | runtime HTTP request | Stateless, deterministic, and safe to retry. |
| Hints | Direct QUIC control, Fast Relay QUIC control, runtime control when available | Non-authoritative optimization only. |
| Live media | Direct QUIC datagram, Fast Relay QUIC datagram, Fast Relay TCP/TLS ordered fallback | Runtime never carries live media. |

Runtime WebSocket is not part of the current runtime-control or live-media
model. Existing compatibility paths must not be selected by new planning and
the production runtime serves them only behind
`TURBO_RUNTIME_WEBSOCKET_COMPATIBILITY_ENABLED=true`.

Runtime control command framing is centralized in
[`backend/runtime/src/control_protocol.rs`](/Users/mau/Development/bb/backend/runtime/src/control_protocol.rs).
Runtime QUIC control, runtime TLS control, and runtime HTTP request handling
share this envelope shape: command kind, operation/idempotency key, `deviceId`,
`userId` or `userHandle`, optional channel/transmit IDs, optional generation,
and a transport-labelled response. Runtime control frames reject live audio
payloads.

Persistent ordered runtime control streams use
[`backend/runtime/src/control_stream.rs`](/Users/mau/Development/bb/backend/runtime/src/control_stream.rs):
newline-delimited runtime-control frames, multiple commands per persistent
connection, command-level errors without closing the stream, and the same
transport-labelled response envelope. The first valid command frame binds the
connection identity from `userId` or `userHandle` plus `deviceId`; later frames
with a different identity are rejected before backend truth is touched. Runtime
TLS wraps this stream in TLS. Runtime QUIC control uses the same command
envelope with QUIC stream delivery.

Runtime TLS uses [`backend/runtime/src/runtime_tls.rs`](/Users/mau/Development/bb/backend/runtime/src/runtime_tls.rs):
Rustls server config, runtime-control ALPN, PEM certificate/key loading, and the
authenticated persistent stream runner/listener boundary. The production
runtime starts the TLS listener when `BEEP_RUNTIME_TLS_CONTROL_BIND`,
`BEEP_RUNTIME_CONTROL_CERT_PEM`, and `BEEP_RUNTIME_CONTROL_KEY_PEM` are set.
Tests prove real Rustls client/server handshakes, command responses, transport
metadata, and runtime state updates through both direct stream IO and a TCP
listener.

Runtime TLS command handling uses the same frame-bound identity rule as runtime
QUIC: first valid frame binds the persistent connection, later mismatches are
rejected, and command-level errors do not close the stream.

Runtime config advertises the control-plane contract explicitly:

| Field | Meaning |
| --- | --- |
| `runtimeControl.preference` | Ordered control-lane preference: runtime QUIC, runtime TLS, then HTTP unless overridden by config. |
| `runtimeControl.quic` | Runtime QUIC support, endpoint, migration flag, and ALPN `beep-runtime-control-v1`. |
| `runtimeControl.tls` | Runtime TCP/TLS support and endpoint for UDP-blocked networks. |
| `runtimeControl.http` | Stateless bootstrap, recovery, health, and deterministic command fallback. |

Runtime QUIC server configuration lives in
[`backend/runtime/src/runtime_quic.rs`](/Users/mau/Development/bb/backend/runtime/src/runtime_quic.rs).
It owns the runtime-side `quiche` server configuration, runtime-control ALPN,
stream-oriented limits, active-migration configuration, newline-delimited
runtime-control stream adapter, UDP socket loop, and endpoint state machine.
The production runtime starts the QUIC listener when
`BEEP_RUNTIME_QUIC_CONTROL_BIND`, `BEEP_RUNTIME_CONTROL_CERT_PEM`, and
`BEEP_RUNTIME_CONTROL_KEY_PEM` are set. Tests prove command response, identity
mismatch rejection, live-media rejection, and runtime state mutation over real
in-memory `quiche` client/server connections plus the UDP endpoint path.
It uses `quiche`, the runtime-control ALPN, stream-oriented limits, and the
same active-migration law as Fast Relay. The module also owns the QUIC stream
adapter that reads newline-delimited runtime-control frames and writes
transport-labelled responses on the same stream, plus a UDP endpoint primitive
that accepts packets, manages runtime QUIC connections, binds identity from
the first command frame, and emits outbound packets. Tests prove command
handling, identity mismatch rejection, and live-media rejection over real
in-memory `quiche` client/server connections, plus presence commands mutating
runtime state through both stream and UDP endpoint paths. Production config
must advertise runtime QUIC only when the UDP socket, cert/key config, and
lifecycle are enabled.

## State Ownership

| State | Owner | Rule |
| --- | --- | --- |
| Account identity, profile names, remembered contacts, Beep Threads | Postgres | Durable. Must survive runtime restart, deploy, and Redis flush. Beep Thread pending projections and stale-action aliases are derived from this durable row set. |
| Conversation, Participant, Device, Session, Presence, Readiness snapshots used by kernel decisions | Postgres | Durable enough to rebuild kernel input and fence Talk Turn decisions. |
| Current Talk Turn, replay facts, operation idempotency, post-commit outbox, control authorization facts | Postgres | Durable control-plane truth. |
| Control owner routing, drain/lease records, fast coordination records | Redis | Ephemeral. A Redis flush may force reconnect or re-election but must not delete identity, contacts, Conversation, Participant, Device, or Talk Turn truth. |
| Derived contact summaries or other route projections | Optional Redis cache | Cache only. Writes commit to Postgres first and invalidate or refresh cached projections. |
| In-process HTTP state | Rust process memory | Reconstructable transient state only: live sockets, local route observations, recent dev diagnostics, and short-lived compatibility projections. |

If a user-visible fact should still be true after a runtime restart, it belongs in Postgres. Redis is allowed only when loss is bounded, self-healing, or explicitly a cache of Postgres-owned truth.

## Reliability Gate

Use:

```bash
just beepbeep-backend-gate
just beepbeep-backend-production-gate https://api.beepbeep.to
```

The gate regenerates and validates the active proof artifacts. A production bug is not fixed until it is promoted to the lowest replayable proof lane that owns the failure.

## Namespace

Active Unison kernel definitions live under `beepbeep.*` in `bb/main`.

The old `turbo.*` backend and old `turbo.kernel.*` definitions are retained as reference material only. New kernel work belongs under `beepbeep.*`.
