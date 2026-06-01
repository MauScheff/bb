# Turbo Cloudflare APNs Worker

Interim APNs sender while hosted Unison Cloud waits on runtime support for:

- TLS ALPN / HTTP/2 support needed for APNs transport
- built-in P-256 / ECDSA support needed for ES256 signing

Turbo remains authoritative for:

- wake target selection
- `begin-transmit` rules
- wake event identity and diagnostics

This Worker is only a transport adapter. It also owns APNs provider-token reuse so the backend does not churn JWTs on every wake send.

## Why this exists

Long-term goal remains direct APNs-from-Unison. Until Cloud runtime supports it, backend calls this Worker instead of Apple directly.

## Routes

### `GET /health`

Returns a simple health payload and whether the required secrets are present.

### `POST /apns/send`

Authenticated generic APNs send endpoint.

Required header:

- `x-turbo-worker-secret: <shared secret>`

Request body:

```json
{
  "token": "<apns-device-token>",
  "payload": {
    "aps": {},
    "event": "transmit-start",
    "channelId": "abc",
    "activeSpeaker": "@blake",
    "senderUserId": "user-blake",
    "senderDeviceId": "device-blake"
  },
  "pushType": "pushtotalk",
  "bundleId": "com.rounded.Turbo",
  "topicSuffix": ".voip-ptt",
  "sandbox": true,
  "priority": 10,
  "expiration": 0,
  "metadata": {
    "wakeAttemptId": "optional-stable-id",
    "channelId": "abc",
    "targetDeviceId": "device-avery"
  }
}
```

Notes:

- `topic` may be sent directly instead of `bundleId` + `topicSuffix`.
- the generic shape is intentional so the same Worker can later send non-PTT APNs pushes too.

Example alert push for an incoming Beep:

```json
{
  "token": "<apns-device-token>",
  "payload": {
    "aps": {
      "alert": {
        "title": "@avery wants to talk",
        "body": "Tap to accept."
      },
      "badge": 2,
      "sound": "default",
      "category": "TURBO_BEEP",
      "interruption-level": "time-sensitive",
      "mutable-content": 1
    },
    "event": "beep",
    "beepId": "beep-123",
    "fromHandle": "@avery",
    "channelId": "abc",
    "deepLink": "beepbeep://conversation?handle=@avery&action=accept&beepId=beep-123&channelId=abc"
  },
  "pushType": "alert",
  "bundleId": "com.rounded.Turbo",
  "sandbox": true,
  "priority": 10
}
```

The `beep` event and `TURBO_BEEP` category are the APNs payload boundary values for alerting someone about an incoming Beep.

For Beeps, `aps.badge` should be the recipient's current count of unique pending incoming Beep senders.

Response shape:

```json
{
  "ok": true,
  "result": "sent",
  "startedAt": "2026-04-15T12:34:56.000Z",
  "status": 200,
  "apnsId": "optional-apns-id",
  "reason": null,
  "body": "",
  "metadata": {
    "wakeAttemptId": "optional-stable-id"
  }
}
```

On Apple rejection:

```json
{
  "ok": false,
  "result": "rejected",
  "status": 400,
  "reason": "BadDeviceToken",
  "body": "{\"reason\":\"BadDeviceToken\"}"
}
```

On Worker exception:

```json
{
  "ok": false,
  "result": "worker-exception",
  "error": "..."
}
```

Implementation note:

- the Worker caches the imported signing key and reuses the APNs provider token for 30 minutes before refreshing
- this avoids Apple `TooManyProviderTokenUpdates` rejections caused by minting a brand-new provider token on every push

## Secrets

Set these with `wrangler secret put`:

- `TURBO_APNS_WORKER_SECRET`
- `TURBO_APNS_TEAM_ID`
- `TURBO_APNS_KEY_ID`
- `TURBO_APNS_PRIVATE_KEY`

Optional:

- `TURBO_APNS_DEFAULT_BUNDLE_ID`
- `TURBO_APNS_DEFAULT_USE_SANDBOX`

## Local commands

Run locally:

```bash
cd cloudflare/apns-worker
wrangler dev
```

Deploy:

```bash
cd cloudflare/apns-worker
wrangler deploy
```

Set secrets:

```bash
cd cloudflare/apns-worker
wrangler secret put TURBO_APNS_WORKER_SECRET
wrangler secret put TURBO_APNS_TEAM_ID
wrangler secret put TURBO_APNS_KEY_ID
wrangler secret put TURBO_APNS_PRIVATE_KEY
```

## First Turbo integration step

The first backend cutover should only change:

- `begin-transmit` still resolves the wake target in Turbo
- the backend calls this Worker instead of Apple
- the backend persists the returned send result into wake events

Do not move wake target selection or readiness logic into Cloudflare.
