# Self-Hosted VM Deployment

Purpose: deploy and operate the production-shaped BeepBeep backend runtime on
Compute Engine.

## Decision

Use process/service boundaries for each backend role:

| Service | Role | Durable truth |
| --- | --- | --- |
| `runtime` | Rust HTTP/WebSocket control plane and effect executor. | Postgres |
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

Measure current compiled-kernel process invocation cost:

```bash
just kernel-invocation-audit
```

Artifact: `/tmp/bb-kernel-invocation-audit.json`.

Measure the resident compiled worker cost:

```bash
just resident-kernel-invocation-audit
```

Artifact: `/tmp/bb-resident-kernel-invocation-audit.json`.

The VM image defaults `TURBO_KERNEL_WORKER_MODE=resident`. Rust keeps one
compiled UCM worker alive, writes newline-delimited JSON requests to stdin, and
reads stdout through a PTY so UCM flushes each `printLine` response.

Dry-run the VM deployment plan:

```bash
just gce-self-hosted-deploy-dry-run
```

Deploy runtime, Postgres, and Redis to the self-hosted VM:

```bash
just gce-self-hosted-deploy
```

The API VM deploy is registry-backed. It builds and pushes
`europe-west6-docker.pkg.dev/<project>/turbo/turbo-self-hosted:<git-sha>`,
exports/imports BuildKit cache through
`europe-west6-docker.pkg.dev/<project>/turbo/turbo-self-hosted:buildcache`,
copies only the Compose/SQL deploy bundle to the VM, then runs
`docker compose pull` and `docker compose up -d --no-build`.

Live deploys require a clean git worktree. Use `--allow-dirty` only for an
intentional dirty deploy; the script appends `-dirty-<timestamp>` to the image
tag unless `--image-tag` is explicit.

The runtime image depends on `backend/relay-protocol`, not the full
`backend/relay` crate, and does not include `/usr/local/bin/beepbeep-relay`.

Dry-run the dedicated relay VM deployment plan:

```bash
just gce-relay-deploy-dry-run
```

Deploy the dedicated relay image to `turbo-relay-1`:

```bash
just gce-relay-deploy
```

The relay deploy builds/pushes
`europe-west6-docker.pkg.dev/<project>/turbo/beepbeep-relay:<git-sha>` from
`backend/infra/relay/Dockerfile`. It refuses to replace an active
`turbo-relay` systemd service unless the script is run directly with
`--replace-systemd-service`.

## Defaults

| Setting | Default |
| --- | --- |
| Project | active `gcloud` project or `TURBO_GCE_PROJECT` |
| Zone | `TURBO_GCE_ZONE` or `europe-west6-a` |
| Instance | `TURBO_GCE_INSTANCE` or `turbo-self-hosted-1` |
| Remote dir | `/opt/turbo-self-hosted` |
| Runtime port | `8091` |
| Registry location | `TURBO_GCE_REGISTRY_LOCATION` or `europe-west6` |
| Registry repository | `TURBO_GCE_REGISTRY_REPOSITORY` or `turbo` |
| Runtime image | `TURBO_GCE_IMAGE` or `europe-west6-docker.pkg.dev/<project>/turbo/turbo-self-hosted:<git-sha>` |
| Runtime image platform | `TURBO_GCE_IMAGE_PLATFORM` or `linux/amd64` |

The deploy script creates a private remote `.env` file on first install, including a generated Postgres password. Later deploys update the image tag but preserve the same durable volume and credentials. The VM service account needs Artifact Registry read access for the selected repository.

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
