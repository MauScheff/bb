# Production Telemetry

Status: production telemetry reference.
Scope: Cloudflare telemetry worker, Analytics Engine events, backend/app forwarding, queries, alerts, shake reports, and smoke tests.

Production telemetry captures high-signal production facts, not full debug diagnostics.

## Architecture

| Producer / sink | Contract |
| --- | --- |
| iOS app | Emits high-signal client telemetry through backend only. |
| Unison backend | Emits server-side telemetry directly. |
| Cloudflare worker | Writes compact events to Analytics Engine and can mirror alert-worthy events to Discord. |

Rules:

- producers may include `invariantId` when they can prove a local contradiction
- distributed invariants emit correlated facts for reliability intake or merged diagnostics
- worker secret stays server-side
- app never talks to worker directly
- app posts only to `POST /v1/telemetry/events`
- backend forwards authenticated app telemetry to worker as source `ios`

## Event Model

Dataset: `turbo_telemetry_events_v1`.

Envelope fields when available:

- `eventName`
- `source`
- `severity`
- `userId`
- `userHandle`
- `deviceId`
- `sessionId`
- `channelId`
- `peerUserId`
- `peerDeviceId`
- `peerHandle`
- `appVersion`
- `backendVersion`
- `invariantId`
- `phase`
- `reason`
- `message`
- `metadataText`
- `devTraffic`
- `alert`

Send facts that explain production behavior or point directly to contradiction. Keep low-level debug volume in diagnostics.

## Event Coverage

| Family | Events |
| --- | --- |
| iOS connection | `ios.backend.connected` |
| iOS transmit | `ios.transmit.begin_requested`, `ios.transmit.backend_granted`, `ios.transmit.end_requested`, `ios.transmit.system_began`, `ios.transmit.system_ended` |
| iOS wake/PTT | `ios.ptt.incoming_push_received` |
| iOS diagnostics | `ios.error.<subsystem>`, `ios.invariant.violation` |
| iOS reports | `ios.problem_report.shake`, `ios.problem_report.shake_upload_failed` |
| backend channel | `backend.channel.joined`, `backend.channel.left` |
| backend transmit | `backend.transmit.begin_granted`, `backend.transmit.ended` |
| backend presence | `backend.presence.background`, `backend.presence.offline` |
| backend wake | `backend.wake.skipped_config`, `backend.wake.skipped_no_token`, `backend.wake.send_crashed`, `backend.wake.sent`, `backend.wake.failed` |
| backend invariants | `backend.invariant.violation` |

## Runtime Gating

Enabled when backend has:

- `TURBO_TELEMETRY_WORKER_BASE_URL`
- `TURBO_TELEMETRY_WORKER_SECRET`

Optional classification:

- `TURBO_TELEMETRY_DEV_HANDLES`: comma-separated backend-owned dev handles, for example `@avery,@blake,@turbo-ios`

`devTraffic` rules:

- iOS sets `devTraffic=true` for `DEBUG`
- iOS sets `devTraffic=true` when backend mode is non-cloud
- backend sets `devTraffic=true` when emitting handle is in `TURBO_TELEMETRY_DEV_HANDLES`

When configured, backend advertises `"telemetryEnabled": true`, app forwards high-signal telemetry through backend, and backend sends server telemetry directly to worker. When absent, backend advertises false, app hook stays inert, and backend drops production telemetry instead of partially configuring it.

## Worker Setup

Worker source: [`cloudflare/telemetry-worker/README.md`](/Users/mau/Development/bb/README.md).

```bash
just cf-telemetry-worker-deploy
cd cloudflare/telemetry-worker
wrangler secret put TURBO_TELEMETRY_WORKER_SECRET
wrangler secret put TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK
wrangler secret put TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK
wrangler secret put TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK
```

Discord webhooks are optional. Bind the worker to:

```text
https://telemetry.beepbeep.to
```

Worker routes:

- `GET /health`
- `POST /telemetry/events`

## Backend Setup

Before `just deploy`, set:

```bash
export TURBO_TELEMETRY_WORKER_BASE_URL="https://telemetry.beepbeep.to"
export TURBO_TELEMETRY_WORKER_SECRET="..."
just deploy
```

If deployed config still reports telemetry absent, sync from a `direnv` shell and redeploy:

```bash
direnv exec . ucm run bb/main:.turbo.syncDeployConfig
just deploy
```

After deploy, backend exposes `telemetryEnabled` in `GET /v1/config`, accepts authenticated app telemetry at `POST /v1/telemetry/events`, and emits backend-owned telemetry directly to worker.

## Query Setup

Telemetry queries use Cloudflare Analytics Engine SQL API.

```bash
export TURBO_CLOUDFLARE_ACCOUNT_ID="..."
export TURBO_CLOUDFLARE_ANALYTICS_READ_TOKEN="..."
export TURBO_TELEMETRY_DATASET="turbo_telemetry_events_v1"
```

From Codex, GUI apps, or processes that may miss interactive `direnv`, wrap commands with `direnv exec .` from repo root.

`just` commands:

- `just telemetry-query query='SHOW TABLES'`
- `just telemetry-recent hours=24 limit=50`
- `just telemetry-recent-signal hours=24 limit=50`
- `just telemetry-recent-dev hours=24 limit=50`
- `just telemetry-follow hours=1 limit=50 poll=5`
- `just telemetry-follow-signal hours=1 limit=50 poll=5`
- `just telemetry-follow-dev hours=1 limit=50 poll=5`
- `just telemetry-user handle=@avery hours=24 limit=50`

Direct usage:

```bash
direnv exec . python3 scripts/query_telemetry.py --hours 24 --limit 50
direnv exec . python3 scripts/query_telemetry.py --hours 24 --limit 50 --exclude-event-name backend.presence.heartbeat
direnv exec . python3 scripts/query_telemetry.py --hours 1 --limit 50 --follow --poll-seconds 5
direnv exec . python3 scripts/query_telemetry.py --user-handle @avery --hours 24 --limit 50
direnv exec . python3 scripts/query_telemetry.py --hours 24 --limit 50 --dev-traffic true
direnv exec . python3 scripts/query_telemetry.py --query "SHOW TABLES"
```

The helper prints compact operator output by default and supports `--json`.

## Relationship To Diagnostics

Use telemetry for operational questions:

- did an event happen in production?
- which users/devices/channels emitted alerts?
- are backend routes timing out?
- did an invariant fire recently?
- is event stream or Discord alerting configured?

Use merged diagnostics for behavioral questions:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 1 @mau @bau
```

`merged_diagnostics.py` pulls Cloudflare telemetry when credentials exist, then combines it with latest backend diagnostics snapshots. Events with `invariantId` become violations; complete telemetry state facts can become snapshot facts for the same pair/convergence checks used by local diagnostics.

Current shake/manual diagnostics uploads include structured diagnostics with `engineTrace`. Manual/shake upload starts with compact diagnostics, preflights the encoded request body locally, and falls back to smaller diagnostics before attempting an oversized network upload. Automatic debug uploads are compact, byte-budgeted, coalesced, and deferred while live media is active. Extract and replay the exact engine boundary locally before building a new scenario:

```bash
just engine-trace-extract /tmp/turbo-debug/<run>/merged-diagnostics.txt /tmp/turbo-engine-trace.json
just engine-trace-replay /tmp/turbo-engine-trace.json
```

Engine trace replay is the preferred first proof for production, shake, simulator, or physical-device bugs that cross the engine boundary. Use telemetry to find the incident, diagnostics to recover the trace, and replay to reproduce the reducer path without booting the simulator. A fresh report without an extractable trace is a diagnostics export/intake regression unless the build predates trace upload.

Before declaring a production or shake report Apple/PTT/audio-only, classify the boundary explicitly. If the report contains engine intents/events/effects or facts that can be normalized into them, extract/replay the trace or build the smallest engine scenario. If replay is green but the app behavior is wrong, add Swift adapter proof for the effect executor. Use physical retest only for the remaining real Apple/PTT/audio surface.

Checked-in replay fixtures for tooling live in [`fixtures/production_replay/`](/Users/mau/Development/bb/shared/fixtures/production_replay):

- [`merged_diagnostics_mixed.json`](/Users/mau/Development/bb/shared/fixtures/production_replay/merged_diagnostics_mixed.json): one current pair violation plus one historical local violation
- [`merged_diagnostics_pair_matrix.json`](/Users/mau/Development/bb/shared/fixtures/production_replay/merged_diagnostics_pair_matrix.json): multiple current pair violations plus one historical local violation

Split:

- telemetry: recent high-signal facts
- backend latest diagnostics: exact app-instance detail
- merged diagnostics: paired device/backend convergence

Do not put full debug transcripts, engine traces, audio packet logs, routine state captures, or complete local state dumps into Cloudflare telemetry. Those belong in local diagnostics and backend latest diagnostics, especially when shake-to-report uploads transcripts.

## Shake Reports

Shake-to-report works in development, TestFlight, and production-like builds. Flow:

1. app creates local `incidentId`
2. user may add context
3. diagnostics records `Shake report requested`
4. app captures current state projection
5. app uploads compact latest diagnostics to backend, or smaller diagnostics if the compact payload is oversized or times out
6. app emits `ios.problem_report.shake` with `alert=true` when telemetry is enabled

Operator fields:

- `incidentId`: correlate telemetry alert with diagnostic marker
- `userHandle`, `deviceId`: reporting device
- `uploadedAt`: report time
- `diagnosticsLatestURL`: backend latest-diagnostics route for device
- `channelId`, `peerHandle`: selected/active conversation context when present
- `userReport`: optional user context

From Discord, open `diagnosticsLatestURL`. If auth headers are needed:

```bash
just diagnostics-latest <device_id> https://beepbeep.to <user_handle>
```

Behavioral debugging:

```bash
just reliability-intake-shake @mau <incidentId> @bau
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 2 --telemetry-limit 500 --full-metadata <user_handle>
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 2 --telemetry-limit 500 --full-metadata <user_handle> <peer_handle>
just engine-trace-extract /tmp/turbo-debug/<run>/merged-diagnostics.txt /tmp/turbo-engine-trace.json
just engine-trace-replay /tmp/turbo-engine-trace.json
```

Replay/dashboard tooling smoke:

```bash
just audio-incident-replay /tmp/turbo-debug/<run>/audio-incident-corpus.json
just audio-incident-mutate /tmp/turbo-debug/<run>/audio-incident-corpus.json
python3 scripts/audio_incident_corpus.py /tmp/turbo-debug/<run>/merged-diagnostics.json --output /tmp/turbo-debug/<run>/audio-incident-corpus.json --name <name>
python3 scripts/convert_production_replay.py --merged-diagnostics-json fixtures/production_replay/merged_diagnostics_pair_matrix.json --output-dir /tmp/turbo-production-replay-pair-matrix --name fixture_production_replay_pair_matrix
python3 scripts/slo_dashboard.py --merged-diagnostics-json fixtures/production_replay/merged_diagnostics_pair_matrix.json --output-dir /tmp/turbo-slo-dashboard-pair-matrix --name pair-matrix-smoke
```

Reliability intake writes `audio-incident-corpus.json` automatically when merged diagnostics contain replayable audio packet, playout, scheduler, or outbound transport facts. Run `scripts/audio_incident_corpus.py` directly only for a custom source file.

V1 limitation: `diagnosticsLatestURL` is a latest-snapshot pointer, not immutable report URL. Use `incidentId` and `uploadedAt` to confirm the transcript. Later incident-backed routes should key by `incidentId` and allow peer-device reports to attach automatically.

## Alerts

Discord webhook split:

- `TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK`: `#prod-alerts`
- `TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK`: `#prod-telemetry`
- `TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK`: `#prod-dev`
- `TURBO_TELEMETRY_DISCORD_WEBHOOK`: legacy alerts fallback during migration

Alert policy:

- any event with `alert: true`
- any event with severity `critical`

Delivery:

- every accepted event writes to Analytics Engine
- `devTraffic=true` goes only to dev webhook when configured
- dev webhook receives dev stream and dev alerts labeled `DEV STREAM` or `DEV ALERT`
- stream webhook receives curated non-dev operator feed
- explicitly opted-in `ios.diagnostics.state_capture` is excluded from Discord stream to avoid flood
- alerts webhook receives non-dev alert-worthy events only

Discord alerts include source, event name, severity, user identity, device identity, channel identity, and peer identity for Analytics Engine pivot.

## Smoke Test

1. Deploy worker and bind `telemetry.beepbeep.to`.
2. Set `TURBO_TELEMETRY_WORKER_BASE_URL` and `TURBO_TELEMETRY_WORKER_SECRET`.
3. Run `just deploy`.
4. Verify worker:

```bash
curl https://telemetry.beepbeep.to/health
```

5. Verify backend advertises feature:

```bash
curl --fail-with-body -sS https://beepbeep.to/v1/config
```

Expected: `"telemetryEnabled": true`.

6. Open app, connect a dev user, and join or transmit once.
7. Query:

```bash
just telemetry-recent hours=1 limit=20
```

Expected mix: `ios.backend.connected`, iOS transmit events if pressed, backend join/presence/wake events from same interaction.

8. If Discord is configured, force an alert-worthy path and confirm webhook delivery.

## Design Notes

- Production telemetry is separate from debug transcripts.
- Debug diagnostics remain the deep local timeline.
- Telemetry is the searchable, durable, operator-facing summary stream.
- Worker stays thin; selection policy and identity enrichment belong in Turbo.
