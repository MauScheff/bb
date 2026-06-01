# Beep Beep Backend Architecture

Status: active backend architecture.

## Decision

The Beep Beep backend is the canonical control plane.

```text
iOS client
  -> Beep Beep Rust runtime
       HTTP / WebSocket / Postgres / Redis / APNs handoff / QUIC and relay integration
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
| Rust runtime | effects, storage transactions, routing, websocket ownership, APNs integration, QUIC/relay process boundaries, deploy packaging |
| Unison kernel | pure domain meaning, Talk Turn decisions, snapshots, policy, effect plans, corpus fixtures, replay |
| iOS app | client projection, Apple PushToTalk, audio session, capture/playback, UI |
| Archive | old Unison Cloud backend reference only |

Rust may call the kernel once per semantic command. It must not call Unison per audio packet, heartbeat, websocket ping, or QUIC datagram.

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
