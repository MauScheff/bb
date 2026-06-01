# Known Bugs

Agent-facing index of known unresolved issues. Keep entries factual: status, symptoms, proven facts, workaround, and later investigation path.

## Reliability

### Cloudflare APNs worker token reuse is best-effort, not coordinated

Status:
- open
- documented on April 17, 2026 after fixing `TooManyProviderTokenUpdates` rejects in the interim Worker sender

Symptoms:
- long-idle background wake can still fail intermittently even when the sender path is otherwise healthy
- one observed failure class returned APNs reason `TooManyProviderTokenUpdates`
- the current Worker now reuses the APNs provider token in module-scope memory, but that reuse only applies while requests keep landing on the same warm isolate

What is already true:
- the Worker no longer mints a brand-new APNs provider JWT on every wake send
- the current implementation caches both the imported signing key and provider token for 30 minutes inside a warm isolate
- this is enough for the current prototype because it removes the clearly pathological per-request token churn

Why this is still not a full fix:
- Cloudflare Worker global state is isolate-local, not durable
- requests are not guaranteed to hit the same isolate
- isolate lifetime is not stable or controllable enough to treat module-scope cache as authoritative coordination
- a cold start or different isolate can still mint a fresh APNs provider token earlier than ideal

Current workaround:
1. rely on the current Worker cache for prototype/device iteration
2. if background wake becomes flaky again, inspect merged diagnostics for APNs wake outcomes before blaming client state

What to investigate later:
- move APNs provider-token reuse to a more explicit coordination surface if this remains a real reliability issue
- likely options are a Durable Object, another backend-owned shared cache, or full migration back to direct Unison-owned APNs send once the hosted runtime path is ready
- if we keep the Worker path longer-term, add explicit observability for token refresh cadence versus APNs rejection reasons

### Session recovery can degrade into false backend failure until a backend reset

Status:
- open
- observed repeatedly during April 14, 2026 wake / foreground iteration

Symptoms:
- after repeated connect / disconnect / wake testing, both apps can reopen into:
  - `Backend connection failed`
  - `Backend unavailable: the request timed out`
  - `contact sync failed`
  - `channel state refresh failed`
- one or both clients may keep stale local session assumptions:
  - app still thinks it is joined
  - backend contact summaries show no active membership
  - wake / foreground transmit become flaky or slow

Observed backend shape:
- core backend routes like `/v1/config` and `POST /v1/auth/session` can still be healthy
- meanwhile the app can remain in a bad local or partially stale session state
- in at least one reproduced case, `dev/reset-all` restored the system to a healthy reconnect path immediately

Why this matters:
- this is not an acceptable production recovery story
- with many users, the system must recover from stale local/backend session divergence without manual resets

Current workaround:
1. force-quit both apps
2. if startup still shows backend failure on both devices, run `just reset-all`
3. reopen both apps and reconnect from scratch

What to investigate later:
- app-side recovery when backend membership and local joined/system session drift apart
- whether startup sync should clear or invalidate stale local joined/session state more aggressively
- whether timeout bursts on contact summaries / channel state should trigger targeted local reconciliation instead of surfacing as hard backend failure
- whether long-running wake/foreground iteration leaves inconsistent presence/membership/token rows that should self-heal

### Direct backend APNs wake send crashes before any Apple response

Status:
- open
- narrowed on April 14, 2026 during the direct-Unison APNs migration

Symptoms:
- `begin-transmit` returns `wakeDispatch: "attempted"`
- the receiver does not wake
- `/v1/dev/wake-events/recent` records:
  - `result: "send-crashed"`
  - `statusCode: "0"`
- no APNs HTTP status or body is captured

What is already proven:
- deployed backend APNs config is present
- deployed backend signing key parsing works
- deployed backend JWT generation works
- deployed backend can persist wake-event rows
- deployed backend `Http.request` can reach ordinary HTTPS targets:
  - `GET https://www.example.com` returns `status:200`
- deployed backend `Http.request` crashes specifically on the APNs host:
  - `GET https://api.sandbox.push.apple.com/3/device/probe` returns `crashed` from the backend transport probe

Current inference:
- this is not a Turbo token-selection bug
- this is not an app/device wake-state bug
- this is very likely a protocol/runtime mismatch in the deployed Unison HTTP client against APNs-specific transport requirements

Current workaround:
- use legacy/debug APNs tooling for actual wake testing when backend-owned APNs delivery is required
- plan and interim production direction are documented in [APNS_DELIVERY_PLAN.md](/Users/mau/Development/bb/docs/client/APNS_DELIVERY_PLAN.md)

What to investigate later:
- whether deployed Unison `Http.request` supports the protocol features APNs expects on `api.push.apple.com`
- whether the crash is specifically HTTP/2, TLS/ALPN, or another APNs-host-specific transport requirement
- whether Unison Cloud exposes a lower-level or alternate HTTP client path that succeeds against APNs
- whether this should be raised with the Unison team together with the exact hosted repro:
  - `/v1/dev/http-egress-probe` gives `example=status:200` and `apnsSandbox=crashed`
  - a synthetic hosted `begin-transmit` records `send-crashed`
- once the upstream runtime support is merged and deployed, switch back from the interim external sender to direct hosted Unison delivery
