# Turbo Friend Communication Diagrams

Status: diagram specification for agent-authored technical visuals.
Goal: produce two diagrams that explain Turbo Friend communication without implying that media fast paths own Conversation truth.

Required diagrams:

- **Connection Setup + Fast-Path Warming**: how Friends connect, how backend truth remains authoritative, and how hints/prewarm reduce first-talk latency.
- **Hold-To-Talk Audio + Wake + Fallback**: what happens after HOLD, including transmit lease, wake, Apple PushToTalk activation, media E2EE, and transport fallback.

## Principles

- Control plane is authoritative: requests, joins, readiness, wake targeting, websocket signaling authorization, and active-transmit ownership are backend-owned.
- Fast paths are optimizations: Direct QUIC, Fast Relay, receiver prewarm hints, and warm pings reduce latency but never replace backend Conversation truth.
- Audio transport is dynamic: prefer Direct QUIC when active, fall back to Fast Relay when enabled, then backend WebSocket relay.
- Media is end-to-end encrypted before entering Direct QUIC, Fast Relay, or WebSocket relay.

## Legend

```text
[AUTH]  backend-owned session/transmit truth
[WS]    backend WebSocket signaling; authoritative routing, opaque signal payloads
[HTTP]  backend HTTP route
[HINT]  Friend hint or prewarm signal; useful but not authoritative
[MEDIA] media startup, control, or payload delivery path
[WAKE]  PushToTalk wake through APNs
[E2EE]  sealed media payload before transport, opened after receive

solid arrows  = required control flow
dashed arrows = fast-path hint/prewarm
dotted arrows = fallback
```

## Diagram 1: Connection Setup + Fast-Path Warming

This diagram must show that establishing a Conversation is separate from choosing an audio transport.

```text
Friend A iPhone                       Turbo Backend                         Friend B iPhone
-------------                         -------------                         -------------

Open/select Friend
  |
  | [HTTP] /contact-summaries, /channel-state, /readiness
  |-----------------------------------> [AUTH] relationship, membership,
  |                                      audioReadiness, wakeReadiness,
  |                                      Friend device identities
  |<-----------------------------------
  |
Press Connect
  |
  | [HTTP] create/refresh Beep
  |-----------------------------------> [AUTH] stable 1:1 direct channel,
  |                                      Beep Thread relationship,
  |                                      contact summary projection
  |                         [WS/refresh] -------------------------------> Incoming Beep
  |
                                                                            Press Connect
                                                                            accept + join
                                                                            |
                                     [HTTP] accept Beep / join channel       |
  Friend sees friendReady <-------------- [AUTH] membership + active device <--|
                                     [HTTP] upload PushToTalk token
                                     [HTTP] register Direct QUIC identity
                                     [HTTP] register media E2EE identity
                                     [WS] join-accepted hint --------------->
  |
Press Connect again
  |
  | [HTTP] join channel
  |-----------------------------------> [AUTH] both Friends joined,
  |                                      current device leases/presence,
  |                                      /readiness projection
  |<-----------------------------------
  |
  |                         Apps reconcile:
  |                         - backend channel exists
  |                         - local Apple PTT session matches selected Friend
  |                         - backend membership/readiness agrees
  |                         - local media prewarm is sufficient
  |                         - Friend is audio-ready or wake-capable
  v
selected Conversation phase: ready, waitingForPeer, or wakeReady
```

### Fast-Path Warming Lane

Draw these as side channels layered on backend Conversation truth:

```text
Friend A iPhone                                                            Friend B iPhone
-------------                                                              -------------

Selected contact prewarm
  +-- [HINT/WS] selected-friend-prewarm ---------------------------------->
  |
  +-- [HINT/WS] Direct QUIC signaling ------------------------------------>
  |       direct-quic-upgrade-request, offer, answer, ice-candidate, hangup
  |       backend routes/authors signals but treats payload as opaque
  |
  |                                      [MEDIA] Direct QUIC probing
  |<------------------------------------- QUIC negotiation ----------------------------->
  |                                      certificate fingerprint checked
  |                                      path: promoting -> direct
  |                                      failure: timeout/hangup/path-lost -> relay
  |
  +-- [MEDIA] Direct QUIC receiver-prewarm + warm ping/pong ------------->
  |
  +-- [MEDIA] Fast Relay prejoin/prewarm -------------------------------->
  |       relay.beepbeep.to, QUIC 443 or TCP 443
  |       receiver-prewarm request/ack
  |
  +.. [WS] fallback readiness/audio relay ................................>
          receiver-ready, receiver-not-ready, selected-friend-prewarm
```

### Setup Outcomes

- Ready foreground path: both devices joined, local Apple PTT sessions match, local media is prewarmed, Friend `audioReadiness.peer.kind == ready`, and hold-to-talk can enable.
- Wake-ready path: Friend is not foreground-audio-ready, but backend `wakeReadiness.peer.kind == wake-capable`; sender can talk to wake-capable Friend.
- Direct path warmed: Direct QUIC active or warming; first talk can use direct media and receiver prewarm.
- Fast Relay warmed: relay is connected or prejoined; first talk can use relay media/control frames.
- Relayed fallback: backend WebSocket remains available for control and fallback audio relay.

## Diagram 2: Hold-To-Talk Audio + Wake + Fallback

This diagram must show backend transmit ownership, optional wake, media E2EE, and dynamic transport selection.

```text
Friend A Sender                Turbo Backend / Wake Plane             Media Transport            Friend B Receiver
-------------                  --------------------------             ---------------            ---------------

Press HOLD
  |
  | TransmitCoordinator: idle -> requesting
  |
  | [HINT] if warm Direct QUIC or relay exists:
  |-------- receiver transmit-prepare / receiver-prewarm --------------------------------------->|
  |
  | [HTTP] begin-transmit
  |-----------------------------------> [AUTH] verify sender membership
  |                                      [AUTH] resolve target:
  |                                      - foreground-ready device, or
  |                                      - token-backed wake-capable device
  |                                      [AUTH] write active TransmitState lease
  |                                      [AUTH] return transmitId, expiresAt, targetDeviceId
  |<-----------------------------------
  |
  | start lease renewal loop
  | configure outgoing audio route
  | configure media E2EE when Friend identity is available
  |
  | [PushToTalk] request system transmit handoff
  | Apple start beep / system transmit began
  | PTT audio session activated
  | refresh capture against live PlayAndRecord route
  |
  | capture microphone -> encode chunks -> [E2EE] seal payload
  |
  +============================ AUDIO PAYLOAD SELECTION ========================================+
  | 1. [MEDIA] Direct QUIC if active and not forced to relay                                    |
  |        sendAudioPayload(sealedPayload) ----------------------------------------------------->|
  |        on send/path failure: fall back                                                      |
  |                                                                                             |
  | 2. [MEDIA] Fast Relay if enabled/forced/configured                                          |
  |        QUIC 443 or TCP 443                                                                  |
  |        sendAudioPayload(sealedPayload) ----------------------------------------------------->|
  |        on Friend-unavailable/send failure: clear stale relay client, fall back              |
  |                                                                                             |
  | 3. [WS] backend WebSocket relay fallback                                                     |
  |        TurboSignalEnvelope(type: audio-chunk, payload: sealedPayload)                       |
  |-----------------------------------> backend routes authorized signal ----------------------->|
  +=============================================================================================+
                                                                                                 |
                                                                                                 v
                                                                                         receive sealed payload
                                                                                         configure/recover E2EE
                                                                                         open payload
                                                                                         ensure media session
                                                                                         schedule playback
                                                                                         selected phase: receiving
```

### Backend And Wake Effects

Place these near `begin-transmit`, the authoritative ownership decision:

```text
begin-transmit accepted
  |
  +-- [AUTH] active transmit lease exists
  |       - one active transmitter per channel
  |       - lease has transmitId and expiresAt
  |       - sender renews while holding
  |
  +-- [WS] if target has current websocket/session lease:
  |       transmit-start "ptt-prepare" -------------------------------> receiver
  |
  +-- [WAKE] unless target is already audio-ready with open socket:
          backend selects target token
          hosted path: backend -> Cloudflare Worker -> APNs
          desired path: backend -> APNs directly
          Apple PushToTalk wakes receiver
          receiver waits for PTT audio-session activation
```

### Receiver Paths

Foreground:

```text
Receiver active/foreground
  |
  | receives transmit-start, Direct QUIC transmit-prepare,
  | Fast Relay receiver-prewarm, or audio chunk
  v
prewarm/ensure playback media session
publish receiver-ready when receive path and E2EE are ready
open E2EE payloads
schedule playback buffers
show receiving
```

Background or locked:

```text
Receiver backgrounded/locked
  |
  | [WAKE] PushToTalk push received
  |        pending wake candidate = channel + sender device
  |
  | audio/control before Apple activation:
  |        buffer encrypted wake audio
  |        stay in awaitingSystemActivation / signalBuffered
  |
  | Apple PushToTalk activates audio session
  v
systemActivated
  |
  | drain buffered encrypted audio
  | open E2EE payloads
  | schedule playback through system-owned receive path
  v
receiver hears audio during same transmit window
```

Release:

```text
Friend A releases HOLD
  |
  | stop local capture
  | [WS] transmit-stop "ptt-end" -------------------------------------> Friend B
  | [HTTP] end-transmit(transmitId)
  |-----------------------------------> [AUTH] clear active transmit lease
  v
Both sides converge to ready, wakeReady, or waitingForPeer.
```

Warm Direct QUIC fast-start optimization:

```text
Foreground + Direct QUIC active + startup policy allows
  |
  | [HINT/MEDIA] receiver transmit-prepare over Direct QUIC
  | [PushToTalk] system handoff begins
  | [MEDIA] prewarmed Direct QUIC capture may start early
  | [WS] transmit-start "ptt-begin"
  | [MEDIA] sealed audio over Direct QUIC
  |
  +-- on release: [WS] transmit-stop "ptt-end"
  +-- on failure/path lost: fall back to relay path
```

Draw fast-start as an optimization lane, not ordinary backend authority.

## Image Model Prompt

```text
Create a precise technical architecture diagram for Turbo, an iOS Push-to-Talk app.

Panels:
1. "Connection Setup + Fast-Path Warming"
2. "Hold-To-Talk Audio + Wake + Fallback"

Swimlanes, left to right:
1. Friend A iPhone
2. Turbo Backend Control Plane
3. Wake Plane: Cloudflare Worker / APNs / Apple PushToTalk
4. Fast Media Paths
5. Friend B iPhone

Encoding:
- solid black arrows = authoritative backend control-plane actions
- blue dashed arrows = hints or prewarm paths
- green thick arrows = encrypted audio payload delivery
- orange arrows = APNs / Apple PushToTalk wake
- red dotted arrows = fallback after transport failure
- lock icon or "E2EE seal/open" around media before Direct QUIC, Fast Relay, or WebSocket relay
- labels directly on arrows; technical, readable, not marketing

Panel 1 content:
- Friend A opens/selects Friend B.
- Friend A calls /contact-summaries, /channel-state, /readiness.
- Friend A presses Connect; backend creates/refreshes a Beep Thread/channel; Friend B sees incomingBeep.
- Friend B accepts and joins through local Apple PushToTalk/session plus backend join.
- Backend stores membership/current device, PushToTalk token, Direct QUIC identity, and media encryption identity.
- WebSocket join-accepted hint goes from Friend B to Friend A and is labeled "hint; backend remains authority".
- Friend A finishes join.
- Readiness projection includes audioReadiness, wakeReadiness, peerTargetDeviceId, peerDirectQuicIdentity, peerMediaEncryptionIdentity.
- Final states: ready, waitingForPeer, wakeReady.
- Fast Media lane shows selected-friend-prewarm; Direct QUIC signaling (`direct-quic-upgrade-request`, offer, answer, ice-candidate, hangup); Direct QUIC probing `promoting -> direct` with certificate fingerprint verification; receiver-prewarm request/ack and warm ping/pong; Fast Relay prejoin through `relay.beepbeep.to` on QUIC 443 or TCP 443; WebSocket fallback receiver-ready/receiver-not-ready.
- Make explicit that Direct QUIC and Fast Relay do not establish the Conversation; they only warm or carry media/control hints after backend truth exists.

Panel 2 content:
- Friend A presses HOLD; `TransmitCoordinator` moves `idle -> requesting`.
- Optional fast prepare over Direct QUIC or Fast Relay: receiver transmit-prepare / receiver-prewarm.
- Friend A calls backend `begin-transmit`.
- Backend verifies sender membership, resolves target as foreground-ready or token-backed wake-capable, writes active `TransmitState` lease, returns `transmitId`, `expiresAt`, `targetDeviceId`, enforces one active transmitter per channel, and sender renews while holding.
- Backend sends websocket transmit-start `ptt-prepare` when target has a current connected session.
- Backend wake side effect unless target is already audio-ready with open socket: current hosted path backend -> Cloudflare Worker -> APNs -> Apple PushToTalk -> Friend B; desired future path backend -> APNs directly.
- Friend A PushToTalk handoff: request system transmit, Apple start beep, PTT audio session activated, rebind capture to live PlayAndRecord route, capture microphone, encode chunks.
- E2EE: media identities establish X25519-derived key, payload is sealed with ChaCha20-Poly1305 before transport and opened on Friend B.
- Dynamic transport priority: Direct QUIC sendAudioPayload if active; Fast Relay sendAudioPayload if enabled/forced/configured over QUIC 443 or TCP 443; backend WebSocket relay fallback with `TurboSignalEnvelope(type: audio-chunk)`.
- Red dotted fallback arrows from Direct QUIC to Fast Relay and from Fast Relay to WebSocket relay.
- Friend B foreground path: receive transmit-start/prewarm/audio, set active remote participant, ensure playback session, open E2EE, schedule playback, show receiving.
- Friend B background/locked path: PushToTalk push, pending wake candidate, awaitingSystemActivation/signalBuffered, buffer early encrypted audio, Apple activates PTT audio session, drain buffered audio, open E2EE, play during same transmit window.
- Release: Friend A releases HOLD, stops capture, sends websocket transmit-stop `ptt-end`, calls backend `end-transmit(transmitId)`, backend clears active lease, Friends converge to ready/wakeReady/waitingForPeer.
- Callout: warm Direct QUIC fast-start can send receiver transmit-prepare, start prewarmed direct capture, send transmit-start `ptt-begin` over WebSocket, and carry sealed audio over Direct QUIC when Direct QUIC is active and startup policy allows. Draw as optimization, not authority.

Do not draw UDP/TCP as connection setup paths. UDP/QUIC and relay TCP belong only in media transport. Backend WebSocket is required control-plane signaling. Direct QUIC and Fast Relay are media/hint fast paths.
```

## Source Pointers

- `APP_STATE.md`
- `BACKEND.md`
- `APNS_DELIVERY_PLAN.md`
- `Server/backend_architecture.md`
- `Turbo/PTTViewModel+Selection.swift`
- `Turbo/PTTViewModel+Transmit.swift`
- `Turbo/PTTViewModel+TransmitAudioSend.swift`
- `Turbo/PTTViewModel+DirectQuic.swift`
- `Turbo/PTTViewModel+BackendSyncTransportFaultsAndSignals.swift`
- `Turbo/MediaEndToEndEncryption.swift`
- backend definitions: `turbo.service.channels.beginTransmit`, `turbo.store.runtime.beginTransmit`, `turbo.store.runtime.resolveTransmitTarget`, `turbo.service.channels.readiness`
