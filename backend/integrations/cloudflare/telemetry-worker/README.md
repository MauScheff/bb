# Turbo Cloudflare Telemetry Worker

Production telemetry sink for Turbo.

Turbo remains authoritative for:

- which events should be emitted
- user, device, channel, and invariant identity
- alert policy for high-signal failures

Worker responsibilities:

- writes compact structured events to Workers Analytics Engine
- optionally mirrors events to Discord webhooks

## Routes

### `GET /health`

Returns whether the worker has the secret, Analytics Engine binding, and optional Discord webhooks.

### `POST /telemetry/events`

Authenticated telemetry ingest route.

Required header:

- `x-turbo-worker-secret: <shared secret>`

Request body:

```json
{
  "eventName": "backend.invariant.violation",
  "source": "backend",
  "severity": "error",
  "userId": "user-avery",
  "userHandle": "@avery",
  "deviceId": "device-avery",
  "channelId": "channel-123",
  "peerUserId": "user-blake",
  "peerHandle": "@blake",
  "appVersion": "1.0 (42)",
  "backendVersion": "2026-04-23T14:30:00Z",
  "invariantId": "backend.channel_state_conflict",
  "phase": "begin-transmit",
  "reason": "wake-send-failed",
  "message": "backend produced contradictory readiness",
  "metadataText": "{\"statusCode\":\"502\"}",
  "alert": true
}
```

Response shape:

```json
{
  "ok": true,
  "status": "accepted",
  "alerted": true,
  "streamed": true,
  "eventName": "backend.invariant.violation",
  "source": "backend",
  "severity": "error"
}
```

## Analytics Engine layout

The dataset binding is declared in [`wrangler.jsonc`](/Users/mau/Development/bb/backend/integrations/cloudflare/telemetry-worker/wrangler.jsonc).

Blob columns:

1. `eventName`
2. `source`
3. `severity`
4. `userId`
5. `userHandle`
6. `deviceId`
7. `sessionId`
8. `channelId`
9. `peerUserId`
10. `peerDeviceId`
11. `peerHandle`
12. `appVersion`
13. `backendVersion`
14. `invariantId`
15. `phase`
16. `reason`
17. `message`
18. `metadataText`

Double columns:

1. constant event count (`1`)
2. alert flag (`0` or `1`)
3. severity rank

Index column:

- `userId`, falling back to `deviceId`, then `channelId`, then `source:eventName`

## Secrets

Set these with `wrangler secret put`:

- `TURBO_TELEMETRY_WORKER_SECRET`

Optional:

- `TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK`
- `TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK`
- `TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK`

Legacy fallback:

- `TURBO_TELEMETRY_DISCORD_WEBHOOK`

Delivery behavior:

- `TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK` receives `devTraffic=true` events only, labeled as either `DEV STREAM` or `DEV ALERT`
- when the dev webhook is configured, `devTraffic=true` events do not go to the main stream or alerts webhooks
- `TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK` receives non-dev telemetry events that pass the stream filter
- `TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK` receives only non-dev alert-worthy events
- if the new alerts webhook is unset, `TURBO_TELEMETRY_DISCORD_WEBHOOK` is used as an alerts fallback
- `backend.presence.heartbeat` and explicitly opted-in `ios.diagnostics.state_capture` events are written to Analytics Engine, but are excluded from Discord stream delivery because they are high-volume timeline facts

## Local commands

Run locally:

```bash
cd cloudflare/telemetry-worker
wrangler dev
```

Deploy:

```bash
cd cloudflare/telemetry-worker
wrangler deploy
```

Run tests:

```bash
node --test cloudflare/telemetry-worker/src/index.test.js
```

## First query

After the first event is written, the dataset is created automatically.

```bash
python3 tools/scripts/query_telemetry.py --query "SHOW TABLES"
python3 tools/scripts/query_telemetry.py --limit 20 --hours 24
```
