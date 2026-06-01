# Self-Hosted VM Deployment

Purpose: deploy and operate the production-shaped BeepBeep backend runtime on
Compute Engine.

## Decision

Use process/service boundaries for each backend role:

| Service | Role | Durable truth |
| --- | --- | --- |
| `runtime` | Rust HTTP/WebSocket control plane and effect executor. | Postgres |
| `relay` | BeepBeep relay module: QUIC datagram packet media plus TCP fallback. | None; session state is rebuildable |
| `postgres` | Durable runtime state. | Persistent Docker volume |
| `redis` | TTL presence, owner records, pub/sub, and short-lived coordination. | Rebuildable cache only |
| compiled Unison kernel | Pure Talk Turn decisions. | Versioned `.uc` artifacts in the image |

Current production keeps the API runtime and media relay on separate VMs because
both nginx/API and relay TCP/TLS fallback need TCP `443`. This avoids a stream
router while keeping the operational model simple.

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

Optional future path: deploy and let Docker Compose own the backend relay
profile on TCP/UDP `443`:

```bash
just gce-self-hosted-deploy-relay
```

Do not use the relay recipe on the API VM while nginx owns TCP `443`, or while
the dedicated `turbo-relay` systemd service owns `relay.beepbeep.to`.

## Defaults

| Setting | Default |
| --- | --- |
| Project | active `gcloud` project or `TURBO_GCE_PROJECT` |
| Zone | `TURBO_GCE_ZONE` or `europe-west6-a` |
| Instance | `TURBO_GCE_INSTANCE` or `turbo-self-hosted-1` |
| Remote dir | `/opt/turbo-self-hosted` |
| Runtime port | `8091` |

The deploy script creates a private remote `.env` file on first install, including a generated Postgres password. Later deploys update the image tag but preserve the same durable volume and credentials.

## Current Production VMs

| Role | Instance | Static IP | Endpoint | Ports |
| --- | --- | --- | --- | --- |
| API/control plane | `turbo-self-hosted-1` | `34.158.24.229` | `https://api.beepbeep.to` | nginx TCP `443`, runtime `8091` private/local |
| Media relay | `turbo-relay-1` | `34.65.146.215` | `relay.beepbeep.to` | UDP `443`, TCP `443` |

Both VMs are in project `beep-beep-495919`, zone `europe-west6-a`.

The API VM runs `postgres`, `redis`, `runtime`, and nginx. It does not run the
Docker Compose `relay` profile. The relay VM runs the `turbo-relay` systemd
service directly.

## Done Condition

A VM deploy is usable when:

- `docker compose ps` shows `postgres`, `redis`, and `runtime` healthy/running.
- `curl http://127.0.0.1:8091/s/turbo/v1/health` succeeds on the VM.
- `just beepbeep-backend-production-gate https://api.beepbeep.to` passes.
- Relay canaries pass against `relay.beepbeep.to:443`.
- Physical-device proof covers the Apple PushToTalk/audio cells after lower
  backend lanes are green.
