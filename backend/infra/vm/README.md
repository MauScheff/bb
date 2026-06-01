# Self-Hosted VM Deployment

Purpose: deploy the production-shaped self-hosted Turbo runtime to one Compute Engine VM.

## Decision

Use one VM, but keep separate services:

| Service | Role | Durable truth |
| --- | --- | --- |
| `runtime` | Rust HTTP/WebSocket control plane and effect executor. | Postgres |
| `relay` | QUIC datagram packet media plus TCP fallback. | None; session state is rebuildable |
| `postgres` | Durable runtime state. | Persistent Docker volume |
| `redis` | TTL presence, owner records, pub/sub, and short-lived coordination. | Rebuildable cache only |
| compiled Unison kernel | Pure Talk Turn decisions. | Versioned `.uc` artifacts in the image |

Co-location keeps staging and early production simple. Process/container separation keeps logs, restarts, health checks, and later GKE or Cloud SQL migration clean.

## Redis Rule

Redis is allowed for fast ephemeral coordination only:

- presence TTLs
- WebSocket owner records
- pub/sub fanout
- short-lived idempotency/leases

Postgres remains the recovery source. A Redis flush must degrade or force reconnects, not corrupt Conversation, Participant, Device, or Talk Turn truth.

## Commands

Compile kernel artifacts:

```bash
just kernel-compile
```

Dry-run the VM deployment plan:

```bash
just gce-self-hosted-deploy-dry-run
```

Deploy runtime, Postgres, and Redis to the self-hosted VM:

```bash
just gce-self-hosted-deploy
```

Deploy and let Docker Compose own the relay on TCP/UDP `443`:

```bash
just gce-self-hosted-deploy-relay
```

Do not use the relay recipe while the existing `turbo-relay` systemd service is still bound to port `443`.

## Defaults

| Setting | Default |
| --- | --- |
| Project | active `gcloud` project or `TURBO_GCE_PROJECT` |
| Zone | `TURBO_GCE_ZONE` or `europe-west6-a` |
| Instance | `TURBO_GCE_INSTANCE` or `turbo-self-hosted-1` |
| Remote dir | `/opt/turbo-self-hosted` |
| Runtime port | `8091` |

The deploy script creates a private remote `.env` file on first install, including a generated Postgres password. Later deploys update the image tag but preserve the same durable volume and credentials.

## Current VM

| Setting | Value |
| --- | --- |
| Project | `beep-beep-495919` |
| Zone | `europe-west6-a` |
| Instance | `turbo-self-hosted-1` |
| Static IP | `34.158.24.229` |
| Runtime health | `http://34.158.24.229:8091/s/turbo/v1/health` |

The current deployed VM runs `postgres`, `redis`, and `runtime`. It does not run the `relay` profile yet. The existing relay VM remains untouched until DNS, TLS, and TCP/UDP `443` ownership are switched deliberately.

## Done Condition

A VM deploy is usable when:

- `docker compose ps` shows `postgres`, `redis`, and `runtime` healthy/running.
- `curl http://127.0.0.1:8091/s/turbo/v1/health` succeeds on the VM.
- `just self-hosted-cutover-readiness` consumes fresh runtime, storage, websocket, simulator, and physical-device evidence before any production cutover.
