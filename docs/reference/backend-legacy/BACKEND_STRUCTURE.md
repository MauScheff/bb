# Backend Structure

Status: quick index.
Scope: high-level Unison backend namespace map. For exact current definitions, inspect `bb/main` through MCP/UCM.

Source of truth:

- the Unison codebase `bb/main`, inspected via MCP
- supporting repo docs: [`BACKEND.md`](/Users/mau/Development/bb/docs/backend/BACKEND.md), [`Server/backend_architecture.md`](/Users/mau/Development/bb/Server/backend_architecture.md)

Snapshot: observed through MCP on `2026-04-20`; trust MCP/UCM when names differ.

## Mental model

Backend layers:

1. `turbo.domain`
   - shared domain types and derived state helpers
2. `turbo.store.*`
   - storage and query modules over Unison Cloud tables
3. `turbo.service.*`
   - HTTP and websocket route handlers
4. `turbo.*`
   - deployment, local serving, auth/config helpers, APNs support

The backend is a control plane, not a media plane. It owns identity, channels, Beeps, presence, readiness, wake targeting, signaling authorization, and active-transmit state.

## Top-level entrypoints

| Namespace / Definition | What it does |
| --- | --- |
| `turbo.deploy` | Deploys the combined HTTP + websocket service, syncs APNs-related env vars into cloud config, binds the service name/domain. |
| `turbo.serveLocal` | Runs the same backend locally on Unison Local Cloud, using the combined web service and local database. |
| `turbo.service.web` | Combined service surface: `HTTP routes OR websocket route`. |
| `turbo.service.http` / `turbo.service.httpWithConfig` | Main HTTP route composition. |
| `turbo.service.ws` | Websocket connection lifecycle: auth, session connect/touch/disconnect, socket registration, queued envelope delivery, message handling. |
| `turbo.auth.requireUser` | Current dev-auth boundary. Resolves the caller from the dev handle and ensures a backend user exists. |

## Namespace Table Of Contents

### Core support namespaces

| Namespace | What it owns |
| --- | --- |
| `turbo.auth` | Dev auth/session lookup used by route handlers. |
| `turbo.apns.internal` | Direct APNs wake push building and sending, JWT/header/payload construction, wake-event append. |
| `turbo.apns.jwt` | APNs JWT signing input helper. |
| `turbo.apns.worker.internal` | Interim worker-backed APNs send path, including Beep alert payloads and wake sends. |
| `turbo.crypto.bytes` | Byte/base64url helpers used by APNs/JWT code. |
| `turbo.crypto.integer` | Integer math helpers for crypto support such as modular arithmetic. |
| `turbo.deploy.internal` | Env lookup and APNs private-key resolution/sync helpers used during deploy. |
| `turbo.schemaDrift` | Pre-deploy persisted-value fixture hashes and deserialize checks for Unison Cloud storage schema drift. |

### Domain model

`turbo.domain` is the backend vocabulary. It contains both durable entity types and control-plane state machines / derived status helpers.

| Domain area | Main types / helpers |
| --- | --- |
| Identity and addressing | `UserId`, `DeviceId`, `ChannelId`, `BeepThreadId` and conversions |
| Durable entities | `User`, `Device`, `DirectChannel`, `ChannelMembership`, `BeepThread`, `EphemeralToken` |
| Presence/session runtime | `DevicePresence`, `DevicePresenceStatus`, `DeviceSession`, `TransmitState` |
| Signaling | `SignalEnvelope`, `SignalKind`, `SignalInbox` |
| Contact/channel derived state | `ChannelMembershipView`, `BeepThreadProjection`, `ChannelStateStatus`, `ContactSummaryStatus` |
| Readiness/wake state | `AudioReadinessStatus`, `ChannelAudioReadiness`, `ChannelReadinessStatus`, `WakeCapabilityStatus`, `ChannelWakeReadiness`, `ReceiverAudioReadinessRecord` |
| Dev/ops records | `DevDiagnosticsReport`, `DevWakeEvent`, `WakeJob`, `WakeJobKey` |

What `turbo.domain` is doing in practice:

- canonical IDs and records for backend truth
- derived "what state is this relationship/channel in?" helpers for the app-facing control plane
- typed signaling/wake concepts so services/stores do not pass raw strings everywhere

### Store layer

`turbo.store.*` modules wrap the `OrderedTable` layout and backend queries.

| Namespace | What it stores / resolves |
| --- | --- |
| `turbo.store.users` | User creation, lookup by handle/id, availability, user tables. |
| `turbo.store.devices` | Registered devices, by-id and by-user projections, alertable device listing. |
| `turbo.store.channels` | Stable direct-channel lookup/creation and per-user channel listing. |
| `turbo.store.memberships` | Channel membership rows and membership existence checks. |
| `turbo.store.beepThreads` | Current direct-channel Beep Thread lifecycle: create/reuse, pending incoming/outgoing, connected/cancelled/declined transitions. |
| `turbo.store.presence` | Online/offline heartbeat state, active channel presence, connected-device selection helpers. |
| `turbo.store.sessions` | Device session records and per-device signaling inbox ownership. |
| `turbo.store.sockets` | Live websocket registry keyed by device. |
| `turbo.store.tokens` | Latest channel-scoped PushToTalk token per `channel + user + device`. |
| `turbo.store.receiverAudioReadiness` | Receiver-ready / receiver-not-ready state for the current session/device. |
| `turbo.store.runtime` | Active transmit lease, current transmitter, renew/end transmit, transmit-target resolution. |
| `turbo.store.devDiagnostics` | Latest uploaded diagnostics per device/user. |
| `turbo.store.devWakeEvents` | Recent wake-event log for debugging APNs/wake flow. |
| `turbo.store.wakeJobs` | Pending worker wake jobs for the internal worker surface. |

Two especially important runtime modules:

- `turbo.store.runtime`
  - owns "who is transmitting right now?" and "who should receive this transmit?"
  - `resolveTransmitTarget` falls back from connected presence to the latest token-backed wake-capable device
- `turbo.store.presence`
  - owns the device-scoped notion of online/joined/current-channel presence
  - websocket signaling authorization is aligned to this layer

### Service layer

`turbo.service.*` turns the store/domain layer into HTTP and websocket behavior.

#### Top-level service composition

| Namespace | What it does |
| --- | --- |
| `turbo.service.http` | Main HTTP surface. |
| `turbo.service.httpWithConfig` | Composes `health`, config, internal routes, dev routes, presence, auth, users, Beeps, and channels. |
| `turbo.service.web` | Combines `service.http` with `service.ws`. |
| `turbo.service.internal` | Shared JSON encoding helpers, worker auth, internal worker routes. |

#### Route groups

| Route namespace | What it handles |
| --- | --- |
| `turbo.service.routes.auth` | Auth/session route plus device registration. |
| `turbo.service.routes.users` | Contact summary, user lookup by handle, presence by handle. |
| `turbo.service.routes.beeps` | Create/accept/decline/cancel Beeps plus incoming/outgoing Beep lists. |
| `turbo.service.routes.channels` | Direct channel lookup, join/leave, state, readiness, token upload, begin/renew/end transmit, wake target lookup. |
| `turbo.service.routes.dev` | Seed/reset, deploy stamp, diagnostics upload/read, runtime inspection, wake-event upload/read. |
| `turbo.service.internal.routes` | Internal wake-job list/finish routes behind worker auth. |

#### Feature modules under `turbo.service.*`

| Namespace | What it does |
| --- | --- |
| `turbo.service.auth` | Auth/session endpoint. |
| `turbo.service.devices` | Device registration endpoint. |
| `turbo.service.users` | User lookup and presence lookup endpoints. |
| `turbo.service.contacts` | Backend-owned contact summary route; only relationship-backed contacts are summarized. |
| `turbo.service.beeps` | Beep creation and state transitions. |
| `turbo.service.channels` | Direct channel control-plane endpoints: join/leave/state/readiness/token/transmit lifecycle. |
| `turbo.service.presence` | Heartbeat and offline routes. |
| `turbo.service.dev` | Dev/test/inspection/reset surfaces. |
| `turbo.service.ws` | Websocket endpoint and message routing. |

Two service modules that matter most for app behavior:

- `turbo.service.channels`
  - owns the channel control-plane API the app uses after auth
  - includes readiness, PTT token ingest, and transmit lifecycle
- `turbo.service.ws`
  - owns the signaling socket lifecycle and envelope forwarding
  - `resolveEnvelopeTarget` only routes when sender and receiver device presence is valid for that channel

## Rough request map

If you need to find a feature quickly, this is the shortest path:

| If you are looking for... | Start here |
| --- | --- |
| dev auth/session | `turbo.auth`, `turbo.service.auth`, `turbo.service.routes.auth` |
| device registration | `turbo.service.devices`, `turbo.store.devices` |
| direct channel creation/lookup | `turbo.service.channels.direct`, `turbo.store.channels` |
| Beep workflow | `turbo.service.beeps`, `turbo.store.beepThreads` |
| contact list / summaries | `turbo.service.contacts`, `turbo.store.channels`, `turbo.store.beepThreads`, `turbo.store.presence`, `turbo.store.runtime` |
| join/leave/presence | `turbo.service.channels.join`, `turbo.service.channels.leave`, `turbo.service.presence`, `turbo.store.presence` |
| readiness / receiver-ready state | `turbo.service.channels.readiness`, `turbo.store.receiverAudioReadiness`, `turbo.domain.*Readiness*` |
| begin/end/renew transmit | `turbo.service.channels.beginTransmit`, `renewTransmit`, `endTransmit`, `turbo.store.runtime` |
| wake targeting / token fallback | `turbo.store.runtime.resolveTransmitTarget`, `turbo.store.tokens`, `turbo.apns.*`, `turbo.store.wakeJobs` |
| websocket signaling | `turbo.service.ws`, `turbo.domain.SignalEnvelope`, `turbo.store.sessions`, `turbo.store.sockets` |
| diagnostics / backend inspection | `turbo.service.dev`, `turbo.store.devDiagnostics`, `turbo.store.devWakeEvents` |
| deploy / local serve | `turbo.deploy`, `turbo.serveLocal` |

## Practical reading order

For most backend changes, this order gets you oriented fastest:

1. `turbo.service.routes.*` or the specific `turbo.service.<feature>` module
2. the corresponding `turbo.store.*` modules
3. `turbo.domain` types and derived-status helpers used by that flow
4. `turbo.service.ws` if signaling or presence is involved
5. `turbo.apns.*` and `turbo.store.wakeJobs` if wake behavior is involved

## Notes on current shape

A few structural facts stand out from the current MCP snapshot:

- the backend is centered on device-scoped truth, not just user-scoped truth
- Beep flow, channel flow, readiness, and signaling are all separate modules, but they meet in `turbo.store.presence` and `turbo.store.runtime`
- contact summaries are backend-derived, not a dumb directory listing
- wake behavior is split between direct APNs helpers and a worker-backed path
- the same combined web service is used for local and deployed environments
