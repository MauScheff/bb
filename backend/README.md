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

Rust owns effects: HTTP, WebSocket, Postgres, Redis, APNs handoff, QUIC/relay integration, process lifecycle, metrics, and deploy packaging.

Unison owns kernel meaning under `beepbeep.*`: command decisions, snapshots, policy, effect plans, corpus fixtures, worker entrypoints, and replayable semantic tests.

The iOS app remains outside this folder and talks to the backend through the existing app-compatible HTTP/WebSocket/QUIC boundary.

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

## Archived Backend

The previous Unison Cloud backend path is preserved under `archive/unison-cloud/` for reference. It is not the active deploy or reliability path.
