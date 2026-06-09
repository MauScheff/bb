# App State Guide

Status: app-visible projection reference.
Authority: selected Conversation UI derivation, readiness/wake projection, and transition examples.
Related docs: [`ENGINE.md`](/Users/mau/Development/bb/ENGINE.md) owns Conversation, Connection, Talk Turn, PTT, media, and low-level transport source-of-truth; [`SWIFT.md`](/Users/mau/Development/bb/docs/client/SWIFT.md) owns Swift architecture; [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/bb/docs/reliability/STATE_MACHINE_TESTING.md) owns scenario proof; [`SWIFT_DEBUGGING.md`](/Users/mau/Development/bb/docs/client/SWIFT_DEBUGGING.md) owns simulator/device debugging loops.

When this guide and `ENGINE.md` disagree, prefer the engine model and update this projection guide.

## Ownership

The app-visible conversation is a projection of smaller authoritative machines:

| Layer | Owner | Code |
| --- | --- | --- |
| Engine state | Conversation, Connection, Talk Turn, PTT, media, and low-level transport source-of-truth | [Packages/TurboEngine](/Users/mau/Development/bb/Packages/TurboEngine) |
| Backend sync | shared control-plane truth: contact summaries, Beeps/Beep Threads, Conversation membership, readiness, wake, and Talk Turn authority | [Turbo/BackendSync.swift](/Users/mau/Development/bb/client/ios/Turbo/BackendSync.swift), [Turbo/BackendSyncCoordinator.swift](/Users/mau/Development/bb/client/ios/Turbo/BackendSyncCoordinator.swift) |
| Device PTT | Apple PushToTalk channel evidence needed to restore or align the local Device | [Turbo/PTTCoordinator.swift](/Users/mau/Development/bb/client/ios/Turbo/PTTCoordinator.swift) |
| Transmit | local hold/release lifecycle and lease edge effects | [Turbo/TransmitCoordinator.swift](/Users/mau/Development/bb/client/ios/Turbo/TransmitCoordinator.swift) |
| Selected Conversation | user-visible selected Conversation projection | [Turbo/ConversationDomain.swift](/Users/mau/Development/bb/client/ios/Turbo/ConversationDomain.swift), [Turbo/SelectedConversationProjection.swift](/Users/mau/Development/bb/client/ios/Turbo/SelectedConversationProjection.swift) |

Rules:

- Backend owns Beeps/Beep Threads, membership, readiness, wake capability, and Talk Turn transmit authority.
- Apple owns the Device PTT channel lifecycle.
- `TurboEngine` owns app-internal Conversation, Connection, Talk Turn, PTT, media, and low-level transport state.
- UI booleans are derived views only; they are not source-of-truth state.

## Core States

### Conversation Status

`ConversationState` is the coarse backend-facing status:

- `idle`
- `outgoing-beep`
- `incoming-beep`
- `waiting-for-peer`
- `ready`
- `self-transmitting`
- `peer-transmitting`

This is not the full UI state. It is refined into `SelectedConversationPhase`.
The `outgoing-beep` and `incoming-beep` values name pending Beep direction across backend routes, scenarios, diagnostics, and app projection.

### Beep Thread Relationship

`BeepThreadProjection` encodes the current Beep Thread between the selected Friends:

- `none`
- `outgoingBeep(requestCount:)`
- `incomingBeep(requestCount:)`
- `mutualBeep(requestCount:)`

`mutualBeep` preserves simultaneous-Beep evidence long enough to cancel the superseded outgoing Beep and accept the incoming one deterministically. Backend wire booleans may exist, but Swift converts them into this internal shape immediately.

### Selected Conversation Projection

`SelectedConversationPhase` is the existing type name for the user-visible selected Conversation state machine:

- `idle`: no active Beep or Conversation
- `outgoingBeep`: local user sent a Beep
- `incomingBeep`: Friend sent a Beep; `SelectedConversationDetail` carries this as `incomingBeep(requestCount:)`
- `friendReady`: Friend joined; local user can finish Connection setup
- `wakeReady`: hold-to-talk can wake the Friend
- `waitingForPeer`: local/system/backend alignment is still converging
- `localJoinFailed`: local PTT join failed and blocks automatic restore
- `ready`: both sides are joined and hold-to-talk can enable
- `startingTransmit`: transmit granted, media/audio startup in progress
- `transmitting`: local user is talking
- `receiving`: Friend is talking
- `blockedByOtherSession`: another contact owns the active Device PTT channel evidence
- `systemMismatch`: Apple restored or exposed an unmappable PTT channel

`SelectedConversationDetail` carries state-specific payloads inside cases, for example `idle(isOnline:)`, `outgoingBeep(requestCount:)`, `incomingBeep(requestCount:)`, `waitingForPeer(reason:)`, `localJoinFailed(recoveryMessage:)`, and `startingTransmit(mediaState:)`.

### Device PTT

`PTTCoordinator` tracks OS-level PTT evidence:

- `none`: no known Device PTT evidence
- `active(contactID:, channelUUID:)`: Device is joined to a known contact PTT channel
- `mismatched(channelUUID:)`: device has a system channel the app cannot map confidently

Legacy compatibility fields such as joined/transmitting flags may be derived at UI or adapter boundaries. They must not become new internal source-of-truth.

### Transmit

`TransmitCoordinator` tracks the local Talk Turn press lifecycle:

- `idle`
- `requesting(contactID:)`: user is pressing; backend lease request is pending
- `active(contactID:)`: lease granted and local activation is in progress or active
- `stopping(contactID:)`: release or failure is ending transmit

This is separate from `SelectedConversationPhase`; a conversation can be `ready` while transmit is `idle`.

### Media

Media pipeline states:

- `idle`
- `preparing`
- `connected`
- `failed(String)`
- `closed`

This permits `startingTransmit`: backend granted transmit before audio is fully connected.

## Readiness ADTs

The domain layer normalizes readiness before deriving UI:

- `DevicePTTReadiness`: `none`, `partial`, `aligned`
- `BackendChannelReadiness`: `absent`, `peerOnly(peerDeviceConnected:, canTransmit:, status:)`, `selfOnly(canTransmit:, status:)`, `both(peerDeviceConnected:, canTransmit:, status:)`

These replace repeated boolean recombination such as Device PTT evidence, Apple system-channel match, selected-contact match, and backend membership checks. Normalize once, then pattern-match in effective-state derivation, selected Conversation projection, and reconciliation.

Wire models are normalized into stronger projections before domain logic:

- `BackendBeepThreadProjection`: `none`, `outgoing(requestCount:)`, `incoming(requestCount:)`, `mutual(requestCount:)`
- `TurboSummaryBadgeStatus`: `offline`, `online`, `outgoingBeep`, `incoming`, `idle`, `waitingForPeer`, `ready`, `transmitting`, `receiving`, `unknown(String)`
- `TurboConversationStatus`: `idle`, `outgoingBeep`, `incomingBeep`, `connecting`, `waitingForPeer`, `ready`, `selfTransmitting(activeTransmitterUserId:)`, `peerTransmitting(activeTransmitterUserId:)`, `unknown(String)`
- `TurboChannelReadinessStatus`: `waitingForSelf`, `waitingForPeer`, `ready`, `selfTransmitting(activeTransmitterUserId:)`, `peerTransmitting(activeTransmitterUserId:)`, `unknown(String)`
- `TurboChannelMembership`: `absent`, `peerOnly(peerDeviceConnected:)`, `selfOnly`, `both(peerDeviceConnected:)`

Preferred backend contract:

| Field | Shape |
| --- | --- |
| `beepThreadProjection` | `kind`, `requestCount` |
| `membership` | `kind`, `peerDeviceConnected` |
| `summaryStatus` | `kind`, `activeTransmitterUserId`; wire `connecting`/`talking` normalize to `waitingForPeer`/`transmitting` |
| `conversationStatus` | `kind`, `activeTransmitterUserId` |
| `readiness` | `kind`, `activeTransmitterUserId` |
| `audioReadiness` | `self.kind`, `peer.kind`, `peerTargetDeviceId` |
| `wakeReadiness` | `self.kind`, `self.targetDeviceId`, `peer.kind`, `peer.targetDeviceId` |

`TurboContactSummaryResponse`, `TurboChannelStateResponse`, and `TurboChannelReadinessResponse` require the nested contract at decode time. Flat `badgeStatus`, `status`, join flags, peer-device flag, and `activeTransmitterUserId` may remain on the wire for observability or redundancy, but Swift no longer falls back to them when nested ADTs are missing or malformed.

Canonical backend inputs:

- `/contact-summaries`: relationship and badge projection
- `/channel-state`: membership projection
- `/readiness`: readiness and transmit authority
- `/readiness.wakeReadiness`: disconnected peer wake capability for this channel

Selected Conversation derivation uses `/readiness` directly rather than reconstructing readiness from flat join fields.

## Wake Activation

Background and lock-screen receive use a local wake-activation ADT separate from backend `audioReadiness` and `wakeReadiness`:

- `signalBuffered`: runtime-control transmit-start or wake audio arrived before confirmed incoming PTT push
- `awaitingSystemActivation`: incoming PTT push received; app waits for Apple PushToTalk audio-session activation
- `fallbackDeferredUntilForeground`: wake audio exists but app is inactive/locked, so app-managed playback waits for foreground
- `appManagedFallback`: app is active and drains buffered wake audio through app-managed playback
- `systemActivated`: PushToTalk activated audio session and buffered wake audio can flush through system receive path

This local state explains the handoff between backend truth, push delivery, Apple activation, and app-managed fallback. Do not infer it from generic waiting states.

## Selected Conversation Derivation

`SelectedConversationProjectionState` stores selected-contact inputs:

- current selection
- relationship state
- base conversation state
- Device PTT projection: local joined-channel evidence, Apple PTT state, restore barrier, and join failure
- pending Conversation/Device action: `connect(.requestingBackend(contactID:))`, `connect(.joiningLocal(contactID:))`, `leave(.explicit(contactID:))`, `leave(.reconciledTeardown(contactID:))`
- backend readiness projection: channel readiness plus backend convergence
- Connection projection: media state, Connection path, remote playback continuity, first-talk readiness, and incoming wake activation evidence

After each event, the reducer recomputes:

- `selectedConversationState`
- `reconciliationAction`

Main reconciliation rules:

- backend ready while Device PTT evidence is not aligned -> restore local Device PTT state
- backend gone while Device PTT evidence remains -> tear down local Device PTT state
- Apple reports mismatched Device PTT channel -> tear down instead of presenting usable Conversation

`PendingConversationAction` is the app-owned pending Conversation/Device work. It is an ADT because connect and leave phases carry different payloads: backend Beep, Device PTT join, explicit disconnect, reconciled teardown, and global leave of any active Conversation.

## Happy Path

Canonical scenarios: [beep_accept_ready.json](/Users/mau/Development/bb/shared/scenarios/beep_accept_ready.json), [foreground-ptt.json](/Users/mau/Development/bb/shared/scenarios/foreground-ptt.json).

1. Both Friends open each other: relationship `none`, selected phase `idle`, Device PTT `none`, transmit `idle`.
2. Initiator presses Connect: app creates or refreshes backend Beep; initiator projects `outgoingBeep`, recipient projects `incomingBeep`.
3. Recipient presses Connect: incoming Beep means accept and join; recipient converges through `waitingForPeer` with Device PTT join evidence, initiator sees `friendReady`.
4. Initiator presses Connect again: `friendReady` means finish local join. Once backend readiness, local join, and Device PTT alignment agree, both sides become `ready` with `canTransmitNow=true`.
5. Initiator holds talk: transmit `idle -> requesting -> active`; selected phase moves through `startingTransmit` while media prepares, then `transmitting`; Friend projects `receiving`.
6. Initiator releases: transmit `active -> stopping -> idle`; healthy Conversation returns both sides to `ready`.
7. Either side disconnects: explicit leave tears down local/Device PTT state and backend state; selected Conversation returns to `idle` or Beep-derived state.

`ready` requires backend channel existence, current membership, receiver addressability or wake capability as appropriate, local app alignment, and matching Apple PTT channel. If any required fact lags, UI stays in `waitingForPeer` rather than false-ready.

## Audio Boundary

Foreground `ready` means:

- backend readiness is aligned
- local/Device PTT alignment is correct
- local interactive media prewarm is complete
- backend `audioReadiness.peer` says the Friend's receive path is ready

It does not mean microphone capture is already live. On first transmit, the sender still rebinds capture and input tap to the actual live `PlayAndRecord` route before emitting outbound audio. This prevents stale prewarmed routes from creating correct state transitions with no real audio.

Background/lock-screen receive uses `wakeReady` when backend `wakeReadiness.peer.kind == wake-capable`. A locked receiver that accepted push but has not received Apple audio activation must stay in an explicit waiting state, not `receiving`. Examples:

- `Waiting for system audio activation...`
- `Wake received. Unlock to resume audio.`

Foreground receive contract:

- Friend start moves receiver quickly to `receiving`
- audio chunks arrive during the same transmit window
- playback begins during the same transmit window
- remote stop returns through any needed re-prewarm and converges to `ready`

When the app resigns active or enters background, idle app-managed interactive media should tear down so later wake receive is driven by PushToTalk-owned activation rather than stale foreground `PlayAndRecord` state.

## Transition Sketch

```text
idle -> outgoingBeep -> friendReady -> waitingForPeer -> ready
idle -> incomingBeep -> waitingForPeer -> ready
waitingForPeer -> localJoinFailed
ready -> startingTransmit -> transmitting -> ready
ready -> receiving -> ready
ready -> waitingForPeer
```

This is a sketch. Reducer code is authoritative for edge cases.

## Examples

| Case | Inputs | Derived UI |
| --- | --- | --- |
| Outgoing Beep pending | `outgoingBeep`, no local join, no Device PTT evidence | `outgoingBeep`, status `Beep sent to <name>`, muted `Connect` or cooldown-gated `Beep Again` |
| Friend accepted first | backend membership has Friend joined, local user not joined, no active local Device PTT channel evidence | `friendReady`, status `<name> is ready to connect`, enabled `Connect` |
| Backend ready but local missing | backend says both Friends joined, local app or Apple PTT not aligned | `waitingForPeer`, not `ready` |
| Ready but live route not bound | selected Conversation `ready`, backend readiness aligned, local prewarm complete, user presses hold | `startingTransmit`, then capture rebinds to live `PlayAndRecord`, then outbound chunks flow |
| Device PTT join failed due channel limit | `lastJoinFailure.reason == .channelLimitReached` | `localJoinFailed`, status `Reconnect failed. End conversation and retry.`; no blind automatic restore |
| Other contact owns Device PTT | Device PTT evidence is active for another contact | `blockedByOtherSession`, connect/hold disabled |

## Next Reads

- [SWIFT.md](/Users/mau/Development/bb/docs/client/SWIFT.md)
- [Turbo/ConversationDomain.swift](/Users/mau/Development/bb/client/ios/Turbo/ConversationDomain.swift)
- [Turbo/SelectedConversationProjection.swift](/Users/mau/Development/bb/client/ios/Turbo/SelectedConversationProjection.swift)
- [Turbo/PTTCoordinator.swift](/Users/mau/Development/bb/client/ios/Turbo/PTTCoordinator.swift)
- [Turbo/TransmitCoordinator.swift](/Users/mau/Development/bb/client/ios/Turbo/TransmitCoordinator.swift)
- [scenarios/README.md](/Users/mau/Development/bb/README.md)
- [TurboTests/ConversationTests.swift](/Users/mau/Development/bb/client/ios/TurboTests/ConversationTests.swift)
- [TurboTests/ReadinessTests.swift](/Users/mau/Development/bb/client/ios/TurboTests/ReadinessTests.swift)
