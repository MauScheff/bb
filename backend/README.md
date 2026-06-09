# Beep Beep Backend

Canonical backend workspace for the Rust runtime plus the pure Unison kernel.

Canonical hosted production endpoints:

```text
API/control plane: https://api.beepbeep.to
media relay:       relay.beepbeep.to:443
```

The API and relay are one backend system with separate network roles. The API
VM terminates HTTPS through nginx on TCP `443`; the relay VM binds UDP `443`
for QUIC packet media and TCP `443` for TCP/TLS fallback.

## Active Model

Rust owns effects: HTTP, persistent runtime control transports, Postgres, Redis, APNs handoff, QUIC/relay integration, process lifecycle, metrics, and deploy packaging.

Unison owns kernel meaning under `beepbeep.*`: command decisions, snapshots, policy, effect plans, corpus fixtures, worker entrypoints, and replayable semantic tests.

The iOS app remains outside this folder and talks to the backend through app-compatible runtime control plus Fast Relay media boundaries.

## Transport Law

| Payload class | Legal endpoint/mechanism |
| --- | --- |
| Authoritative commands | runtime QUIC control, runtime TLS control, or runtime HTTP recovery |
| Bootstrap, recovery, health | runtime HTTP request |
| Hints | Direct QUIC control, Fast Relay QUIC control, runtime control when available |
| Live media | Direct QUIC datagrams, Fast Relay QUIC datagrams, Fast Relay TCP/TLS ordered fallback |

The runtime never carries live media. Runtime WebSocket is retired from the
default control model and is not a media fallback; backend `audio-chunk` control
signals are invalid in the current model and clients reject them instead of
treating them as fallback media. The active command preference is runtime QUIC
first, runtime TLS when UDP is blocked, and HTTP for bootstrap/recovery. The
production binary serves WebSocket compatibility only when
`TURBO_RUNTIME_WEBSOCKET_COMPATIBILITY_ENABLED=true` is set.

`GET /v1/config` exposes this model through `runtimeControl.preference`,
`runtimeControl.quic`, `runtimeControl.tls`, and `runtimeControl.http`.
Runtime QUIC control uses ALPN `beep-runtime-control-v1`; Fast Relay QUIC keeps
its relay-specific ALPN.

[`runtime/src/runtime_quic.rs`](/Users/mau/Development/bb/backend/runtime/src/runtime_quic.rs)
owns the runtime-side `quiche` server configuration: runtime-control ALPN,
stream-oriented limits, active-migration configuration, the newline-delimited
runtime-control stream adapter, UDP socket loop, and endpoint state machine
that binds identity from the first valid command frame. Tests prove command
response, identity mismatch rejection, and live-media rejection over real
in-memory `quiche` client/server connections, plus a presence command mutating
runtime state through both stream and UDP endpoint paths. The runtime uses the
same QUIC stack family as Fast Relay while keeping runtime control separate
from relay media. Enable production QUIC control with
`BEEP_RUNTIME_QUIC_CONTROL_BIND`, `BEEP_RUNTIME_CONTROL_CERT_PEM`,
`BEEP_RUNTIME_CONTROL_KEY_PEM`, `BEEP_RUNTIME_SUPPORTS_QUIC_CONTROL=true`, and
`BEEP_RUNTIME_QUIC_CONTROL_ENDPOINT`.

All runtime control transports use the command envelope in
[`runtime/src/control_protocol.rs`](/Users/mau/Development/bb/backend/runtime/src/control_protocol.rs).
The envelope carries command kind, operation/idempotency key, `deviceId`,
`userId` or `userHandle`, optional channel/transmit IDs, and optional
generation. Responses carry the effective transport label and whether the lane
is persistent. Runtime control rejects live audio frames.

Persistent ordered runtime control uses
[`runtime/src/control_stream.rs`](/Users/mau/Development/bb/backend/runtime/src/control_stream.rs).
The stream accepts multiple newline-delimited command frames on one
connection, preserves operation/generation fields in responses, and reports
command-level errors without tearing down the stream. The first valid command
frame binds the connection identity from `userId` or `userHandle` plus
`deviceId`; later frames with a different identity are rejected before backend
truth is touched. Runtime TLS wraps this stream; runtime QUIC control uses the
same envelope on QUIC streams.

[`runtime/src/runtime_tls.rs`](/Users/mau/Development/bb/backend/runtime/src/runtime_tls.rs)
owns the Rustls wrapper: PEM certificate/key loading, runtime-control ALPN, and
the authenticated TLS stream runner/listener boundary. The runtime test suite
includes real Rustls client/server handshake proofs for both direct stream IO
and a TCP listener accepting a runtime TLS control connection. Enable
production TLS control with `BEEP_RUNTIME_TLS_CONTROL_BIND`,
`BEEP_RUNTIME_CONTROL_CERT_PEM`, `BEEP_RUNTIME_CONTROL_KEY_PEM`,
`BEEP_RUNTIME_SUPPORTS_TLS_CONTROL=true`, and
`BEEP_RUNTIME_TLS_CONTROL_ENDPOINT`.

## Proof Ladder

Use the blocking gate before trusting backend or production changes:

```bash
just beepbeep-backend-gate
just beepbeep-backend-production-gate https://api.beepbeep.to
```

Promote every production failure to the lowest replayable lane:

| Owner | Proof lane |
| --- | --- |
| Unison kernel meaning | `just kernel-fuzz` |
| Rust runtime effects/concurrency | `just rust-runtime-fuzz` |
| Postgres/Redis route semantics | `just self-hosted-scenario-fuzz-local <seed> <count>` |
| Hosted compatibility | `just beepbeep-backend-production-gate` |
| Apple/PTT/audio/APNs hardware | physical boundary collection only after lower lanes are green |

Use the general reliability discovery loop from [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md) and [`docs/reliability/fuzz.md`](/Users/mau/Development/bb/docs/reliability/fuzz.md): invariant -> generated interleavings -> replay/shrink -> owner -> narrow regression -> fix -> gate.

For backend-owned failures, promote evidence downward before fixing production behavior: hosted failure -> hosted probe -> self-hosted probe/fuzz -> Rust runtime proof -> Unison kernel proof. Keep seed, count, artifact path, invariant ID, and exact replay command with the fix notes.

## Archived Backend

The previous Unison Cloud backend path is preserved under `archive/unison-cloud/` for reference. It is not the active deploy or reliability path.
