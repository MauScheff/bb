# Glossary

Agent-facing canonical language for Beep/Turbo product concepts, code, tests, diagnostics, and docs.

# Purpose

Use this document as the shared vocabulary for semantic refactors, product copy, state models, diagnostics, and architecture docs.

The goal is not to make every implementation term user-facing. The goal is to keep one clear meaning per concept, one preferred name per meaning, and explicit boundaries where technical systems need narrower words.

# Core Model

A Friend sends a Beep with a Subject. When both Friends are Ready, they enter a Conversation. The Conversation uses a Connection to carry Talk Turns. The Device provides the local phone capabilities needed for the Connection. A Conversation can upgrade to a Call.

```text
Friend
  sends Beep
    with Subject
      waits for Ready
        starts Conversation
          carries Talk Turns through Connection
            depends on Device
          may upgrade to Call
```

# Term Status

| Status | Meaning |
| --- | --- |
| Canonical | Preferred term for product, domain, code, tests, and docs. |
| Restricted | Allowed only inside a specific technical boundary. |
| Deprecated | Existing term to migrate away from when touching nearby code. |
| External | Allowed because an Apple, backend, protocol, or framework API uses it. |

Status may include a qualifier such as `internal` or `role-specific` when it narrows where the term should appear.

# Language Layers

| Layer | Purpose | Terms |
| --- | --- | --- |
| Product | Words users can understand immediately. | Friend, Beep, Subject, Ready, Conversation, Talk Turn, Call |
| Domain | Product concepts as code, docs, tests, and diagnostics. | `Friend`, `Beep`, `BeepSubject`, `Readiness`, `Conversation`, `TalkTurn`, `Call` |
| Delivery | Voice movement inside a Conversation. | `Connection`, `ConnectionState`, direct, relayed, reconnecting |
| Device | Local phone and OS conditions that affect delivery. | microphone, audio session, Push-to-Talk, lock/background, interruption |
| Internal | Architecture and proof words that help humans reason about implementation. | Engine, Reducer, Effect, Projection, Adapter, Scenario, Fuzzing, Invariant, Diagnostics, Trace, Proof Lane |
| External | Required names from Apple, protocols, storage, or dependencies. | PushToTalk, AVAudioSession, URLSession, websocket |

# Language Rules

- Use canonical terms unless an external API requires another word.
- Do not introduce synonyms for existing concepts.
- Keep product/domain concepts separate from delivery and device mechanics.
- Reserve `Call` for the upgraded open voice call, not the push-to-talk Conversation.
- Avoid `Session` for product and domain language unless an external API forces it.
- Use `Friend` for the product relationship and `Participant` for a role inside a Conversation.
- Qualify ambiguous states such as `connected`, `live`, `active`, `joined`, and `current`.
- Use technical terms only inside their boundary.
- Prefer internal canonical terms from this glossary when naming refactor, test, diagnostics, and reliability concepts.
- Treat this glossary as target vocabulary. Existing code may still contain deprecated terms until a scoped refactor removes them.

# Canonical Terms

## Friend

Status: Canonical.

A person the user can Beep.

Product term: Friend.

Code term: `Friend` when modeling the relationship; `Participant` only when modeling a role inside a Conversation.

Rules:

- A Friend can send or receive Beeps.
- A Friend may become a Participant after entering a Conversation.
- Future groups should not make one-to-one product language abstract today.

Avoid:

- peer
- member, unless modeling group membership
- user, when the relationship matters

## Beep

Status: Canonical.

A lightweight request to talk.

Product term: Beep.

Code term: `Beep`; use `TalkRequest` only if a low-level boundary needs an unbranded generic term.

Rules:

- A Beep is not a message.
- A Beep may include a Subject.
- A Beep waits until the other Friend is Ready.
- A Beep can lead to a Conversation.

Avoid:

- message
- invite
- call request
- session request

## Beep Thread

Status: Canonical, internal.

The backend's current direct-channel Beep Thread for Beeps between two Friends.

Product term: Beep.

Code term: `BeepThread`, `BeepThreadId`, `BeepThreadStatus`.

Owner: backend shared truth.

Rules:

- A Beep Thread stores the latest pending Beep for a direct channel.
- Repeated Beeps on the same pending thread refresh the thread and increment `requestCount`.
- Stale request IDs should alias to the current Beep Thread until the backend can reject or converge them safely.
- A completed, declined, or cancelled Beep Thread does not preserve legacy storage rows while there are no production users.

Avoid:

- invite
- request, unless naming a low-level HTTP or notification payload field

## Subject

Status: Canonical.

The short context attached to a Beep: what the user wants to talk about.

Product term: Subject.

Code term: `BeepSubject`.

Rules:

- Use `BeepSubject` in Swift instead of a generic `Subject` type.
- In UI copy, an input can ask what the user wants to talk about without naming the field mechanically.
- A Subject gives the Conversation direction without turning Beep into messaging.

Avoid:

- topic
- message
- prompt
- whatAbout

## Ready

Status: Canonical.

The state where a Friend is willing to enter the Conversation now.

Product term: Ready.

Code term: `Readiness`.

Rules:

- Ready is a user/domain state, not merely network reachability.
- Both Friends must be Ready before the Conversation starts.
- A Friend can be available without being Ready.

Avoid:

- accepted, unless modeling a specific backend transition
- joined
- live
- online, when the meaning is willingness to talk

## Conversation

Status: Canonical.

The human/domain object: Friends are in the same talk space and can communicate by push-to-talk.

Product term: Conversation.

Code term: `Conversation`.

Rules:

- A Conversation starts after both Friends are Ready.
- A Conversation can carry Talk Turns.
- A Conversation may survive Connection or Device interruptions.
- A Conversation can upgrade to a Call.
- A Conversation is not a networking session or Apple audio object.

Avoid:

- session
- room
- channel
- call, unless the experience has upgraded

## Connection

Status: Canonical.

The delivery state that lets voice move inside a Conversation.

Product term: Connection when visible; otherwise hide the machinery behind plain status copy.

Code term: `Connection`, `ConnectionState`, `VoiceConnection` only when voice-specific qualification is needed.

Rules:

- A Connection supports a Conversation.
- A Connection cannot outlive its Conversation.
- A Conversation may continue while its Connection reconnects.
- Direct and relayed are Connection path details.

Avoid:

- conversation, when the meaning is audio delivery
- transport, outside low-level networking files
- connected, unless qualified as Conversation-connected or Connection-connected

## Voice Encoding Policy

Status: Canonical, internal.

The codec decision derived from Connection path evidence and observed packet loss for a Talk Turn.

Product term: not user-facing.

Code term: `OpusVoiceEncodingPolicy`.

Owner: Swift app media adapter.

Rules:

- A policy is a pure value derived from lane evidence and packet-loss observation.
- Reapplying the same policy must be idempotent.
- Packet lanes may spend bits on resilience; reliable fallback lanes should not carry packet-loss FEC.
- Policy diagnostics should expose the chosen bitrate, complexity, FEC, loss hint, VBR, DTX, and bandwidth bounds.

Avoid:

- unqualified codec settings
- scattered Opus flags
- transport policy, when the value only describes codec behavior

## Device

Status: Canonical.

The local phone state that affects whether voice can work.

Product term: Device only when needed; prefer plain copy such as "Allow microphone" or "Reconnecting".

Code term: `DeviceReadiness`, `DeviceAudioState`, `DevicePTTProjection`, `DevicePTTContinuityProjection`, or boundary-specific adapter names.

Rules:

- Device state includes microphone permission, audio session, Push-to-Talk availability, background behavior, lock state, interruptions, and route changes.
- Device state can interrupt a Connection.
- Device state does not create or end a Conversation by itself.
- Device mechanics should stay local to app adapters and platform boundary code.

Avoid:

- platform resource
- system thing
- infrastructure, when a narrower Device term exists

## Talk Turn

Status: Canonical.

One push-to-talk speaking interval inside a Conversation.

Product term: Turn when obvious; Talk Turn when precision helps.

Code term: `TalkTurn`.

Rules:

- A Talk Turn starts when a Participant presses to talk.
- A Talk Turn ends when the Participant releases or the system cancels the turn.
- Only one Talk Turn should be active at a time unless a future group model explicitly changes that invariant.

Avoid:

- transmission, outside media/transport internals
- packet
- voice note

## Call

Status: Canonical, restricted to upgraded open voice.

An upgraded open voice experience beyond push-to-talk.

Product term: Call.

Code term: `Call`, `CallUpgrade`, or `CallState`.

Rules:

- Call is not the default push-to-talk Conversation.
- A Conversation may upgrade to a Call.
- Use Call only when the pressure and behavior are closer to a normal phone call.

Avoid:

- call, when the meaning is Conversation
- activeCall, when the object is still push-to-talk

## Participant

Status: Canonical, role-specific.

A Friend in a Conversation.

Product term: Friend.

Code term: `Participant`.

Rules:

- Use Participant when modeling Conversation membership or Talk Turns.
- Use Friend when modeling the social/product relationship.
- A future group Conversation has Participants; the user still sees Friends or people.

Avoid:

- peer
- user, when a role-specific name is available

## Active Conversation Participant Lease

Status: Canonical, internal.

Backend-derived runtime evidence that a specific User/Device is currently an active Participant in a Conversation.

Product term: not user-facing.

Code term: `ActiveConversationParticipantLease`, `ActiveConversationParticipantPresenceEvidence`, `activeConversationParticipantLeases`.

Owner: backend shared truth.

Rules:

- A lease requires durable Conversation membership, matching channel presence, and connected Device session evidence.
- A lease can authorize backend Conversation projections, signaling, readiness, or Talk Turn routing; stale durable rows alone cannot.
- This is not a Call. It belongs to the push-to-talk Conversation control plane.

Avoid:

- ActiveCallParticipantLease
- activeCallLeases

## Conversation Participant Telemetry

Status: Canonical, internal.

Device and Connection context that one Participant publishes to the other while a Conversation is active, such as audio route and network interface.

Product term: not user-facing.

Code term: `ConversationParticipantTelemetry`, `ConversationNetworkInterface`, `SignalKind.ConversationParticipantTelemetry`, `conversation-participant-telemetry`.

Owner: Swift app adapter emits and consumes the payload; backend runtime signaling routes the opaque signal.

Rules:

- Telemetry describes a Participant's local Device and Connection context; it is not shared Conversation truth.
- Telemetry may help the UI explain audio or network conditions, but it must not authorize Talk Turns or membership.
- This is not a Call. It belongs to the push-to-talk Conversation signal boundary.

Avoid:

- CallPeerTelemetry
- CallContext
- call-context
- activeCallContext

## Available

Status: Canonical, distinct from Ready.

A Friend can currently be reached by the app.

Product term: Available, online only if the UI needs the familiar status.

Code term: `Availability`.

Rules:

- Available means reachable; Ready means willing to talk now.
- Availability can help a user decide whether to send or respond to a Beep.
- Availability alone does not start a Conversation.

Avoid:

- ready, when the Friend has not agreed to talk
- connected, when the meaning is reachability

# Restricted And Deprecated Terms

| Term | Status | Prefer | Rule |
| --- | --- | --- | --- |
| session | Restricted | Conversation, Connection | Use only for external APIs, runtime containers, or framework names that require session. |
| peer | Deprecated | Friend, Participant | Friend for product relationship; Participant inside Conversation logic. |
| invite | Deprecated | Beep, Beep Thread | Beep is the product request; Beep Thread is the backend persisted thread. |
| topic | Deprecated | Subject | Subject is the canonical Beep context; APNs `topic` is an Apple header name and may stay inside APNs delivery code/docs. |
| message | Deprecated for Beep | Beep, Subject | Beep is not messaging; Subject is not a message body. |
| call | Restricted | Conversation | Reserve Call for upgraded open voice. |
| room | Deprecated | Conversation | Avoid importing group-chat metaphors. |
| channel | Restricted | Conversation, Connection | Use only for Apple PushToTalk or transport APIs that require channel. |
| transport | Restricted | Connection | Use only in low-level networking or delivery-path code. |
| live | Deprecated unless copy-only | Ready, Conversation, Connection | Too broad for state models; qualify the actual meaning. |
| active | Deprecated unless qualified | Ready, Conversation, Connection, Talk Turn | Too broad for state models; qualify the actual meaning. |
| connected | Restricted | Conversation-connected, Connection-connected | Always state which layer is connected. |
| current | Deprecated unless UI-local | selected, active, focused | Too vague for shared or durable state. |

## APNs Topic

Status: External.

Apple Push Notification service header and worker payload field used to route pushes to a bundle/topic.

Product term: not user-facing.

Code term: `topic`, `apns-topic`.

Owner: external Apple/APNs boundary.

Rules:

- Use only in APNs worker, probe, and delivery docs.
- Do not use APNs topic language for Beep Subjects.

Avoid:

- Subject

# Conversation, Connection, Device

Use these three layers to collapse technical complexity.

| Layer | Question | Owner |
| --- | --- | --- |
| Conversation | Are these Friends in the same talk space? | Domain/shared truth plus local engine projection |
| Connection | Can voice currently move between them? | Delivery/media/network state |
| Device | Can this phone support voice right now? | Local app and Apple/platform boundary |

Rules:

- Conversation is the product truth.
- Connection is the delivery truth.
- Device is the local phone truth.
- A Conversation may survive Connection or Device interruptions.
- A Connection cannot outlive its Conversation.
- Device state should not become shared truth unless a backend contract explicitly models it.

# Internal Concepts

Use these terms for architecture, tests, diagnostics, reliability, and refactors. They are not product copy.

## Engine

Status: Canonical, internal.

The pure local owner of Conversation, Connection, push-to-talk, media, and transport decisions that can be represented without iOS frameworks.

Code term: `TurboEngine`.

Owner: `Packages/TurboEngine`.

Rules:

- Engine logic should be deterministic and replayable.
- Engine state should be driven by typed events and produce typed Effects.
- Engine-owned behavior should prove through engine tests, scenarios, traces, or fuzzing before simulator or device lanes.

Avoid:

- view model, when the meaning is pure local state transition authority
- app state, when the meaning is engine-owned truth

## Reducer

Status: Canonical, internal.

A pure transition function from state and event to new state plus Effects.

Code term: `Reducer` or reducer-like functions in `TurboEngine`.

Rules:

- Reducers do not perform side effects directly.
- Reducers make state transitions explicit and replayable.
- Prefer reducers when a lifecycle is currently encoded by scattered booleans or cross-boundary conditionals.

Avoid:

- handler, when the function is a pure transition
- manager, when no external resource is managed

## Effect

Status: Canonical, internal.

A typed request for a boundary to do work after a pure state transition.

Code term: `Effect`.

Rules:

- Effects describe what should happen, not how a platform or backend performs it.
- Effects should be idempotent or guarded by explicit identity when retries are possible.
- App, backend, Device, and Connection adapters execute Effects.

Avoid:

- callback, when the value is an owned command
- side effect, when a typed Effect exists

## Projection

Status: Canonical, internal.

A derived view of source truth for UI, diagnostics, backend contracts, or boundary output.

Code term: `Projection`.

Rules:

- A Projection should be derived, not become a second source of truth.
- Projection names should say which truth they project and who consumes them.
- If a Projection stores durable state, reclassify the owner instead of hiding ownership.

Avoid:

- state, when the value is derived
- current, when the selected/focused/visible source is not named

## Adapter

Status: Canonical, internal.

Boundary code that translates between Turbo concepts and external APIs, frameworks, storage, or protocols.

Code term: `Adapter` only when the type is a real boundary; otherwise use the boundary name.

Rules:

- Adapters may use external terms required by Apple, backend routes, storage, or protocols.
- Adapters should not define domain truth.
- Adapters translate Effects into external work and translate external events into domain events.

Avoid:

- service, unless it owns a stable external capability
- manager, when the type only translates across a boundary

## Scenario

Status: Canonical, internal.

A replayable workflow used to prove behavior across a chosen owner or boundary.

Code term: `Scenario`.

Rules:

- Scenarios should name the behavior being proved.
- Prefer engine or headless scenarios before simulator scenarios when they can represent the invariant.
- Scenario artifacts should preserve seed, inputs, commands, and expected outcome.

Avoid:

- script, when the artifact is a behavior proof
- manual repro, when the flow can be made replayable

## Fuzzing

Status: Canonical, internal.

Randomized scenario generation used to discover invariant violations and broaden replay coverage.

Code term: `Fuzzing`, `Fuzz`, or existing repo fuzz command names.

Rules:

- Fuzzing output must be replayable by seed and case.
- Promote discovered failures into smaller deterministic proofs when possible.
- Fuzzing is a proof broadener, not a replacement for a focused invariant test.

Avoid:

- random test, when seed and replay artifact matter
- stress test, when the mechanism is randomized invariant exploration

## Invariant

Status: Canonical, internal.

A named behavior that must always hold.

Code term: `Invariant`.

Rules:

- Invariants should name the impossible state or required convergence rule.
- Invariants need machine-readable evidence when used in diagnostics or production reliability.
- Refactors should preserve existing invariants or explicitly rename/split them.

Avoid:

- check, when the rule is durable product or system behavior
- assertion, when the rule also exists in diagnostics or telemetry

## Diagnostics

Status: Canonical, internal.

Machine-readable evidence about runtime behavior.

Code term: `Diagnostics`.

Rules:

- Diagnostics should use canonical domain terms unless reporting external API fields.
- Diagnostics should preserve enough identity to replay or classify failures.
- Do not make diagnostics the source of truth; they report truth owned elsewhere.

Avoid:

- logs, when the evidence is structured and consumed by tooling
- message, when the value is a typed diagnostic event or invariant

## Trace

Status: Canonical, internal.

An ordered sequence of events captured for replay, debugging, or proof.

Code term: `Trace`.

Rules:

- Traces should preserve event order and enough state to reproduce the behavior lane.
- Use engine traces before simulator or physical-device proof when a failure crosses the engine boundary.
- Trace formats should remain stable enough for replay and diagnostics extraction.

Avoid:

- log, when replay semantics matter
- recording, when the artifact is structured event evidence

## Proof Lane

Status: Canonical, internal.

The narrowest automated route that exercises the owner and failure mode.

Code term: proof lane in docs and handoffs; concrete commands use `just` recipes when available.

Rules:

- Start at the lowest lane that can represent the invariant.
- Stop climbing once the lane exercises the owner and failure mode.
- Use simulator or physical-device lanes only when lower proofs cannot represent the behavior.

Avoid:

- test level
- validation path

# Candidate Rename Ledger

Use this ledger to plan scoped refactors. Do not rename mechanically without checking meaning at each call site.

| Old Term | Target Term | Scope | Notes |
| --- | --- | --- | --- |
| peer | Friend | Product/app relationship surfaces | Use Participant inside Conversation logic. |
| peer | Participant | Conversation membership and Talk Turns | Use only when the person is in a Conversation. |
| peerReady | friendReady | Selected Conversation readiness phase | Friend has become Ready first; local user can finish joining. Keep low-level peer fields at backend/device boundaries until their owner is refactored. |
| topic | Subject | Beep metadata | Prefer `BeepSubject` in Swift. |
| session | Conversation | Domain/product state | Keep session only at external API boundaries. |
| session | Connection | Runtime/delivery state | Use when old session code is really about voice delivery. |
| call | Conversation | Current push-to-talk flow | Reserve Call for upgraded open voice. |
| message | Beep | Request-to-talk flow | Beep is a request, not a chat message. |
| Invite | BeepThread | Backend persisted thread | Use `Beep` for the product request and `BeepThread` for the current stored direct-channel thread. |
| InviteId | BeepThreadId | Backend stored Beep Thread identity | Stale Beep Thread IDs alias to the current Beep Thread while no legacy storage is preserved. |
| InviteStatus | BeepThreadStatus | Backend Beep Thread lifecycle | Pending/connected/declined/cancelled currently describe Beep Thread lifecycle, not a user-facing invite. |
| service.invites / store.invites | service.beeps / store.beepThreads | Backend service/store namespaces | Routes should expose Beep language; storage should expose Beep Thread language. |
| connected | Connection-connected | Delivery state | Do not imply a Conversation lifecycle transition. |
| connected | Conversation-connected | Domain state | Do not imply the network path is healthy. |
| SelectedPeer | Selected Friend | Product/app relationship surfaces | Use only where the selected person is not necessarily in a Conversation. |
| SelectedPeer | Selected Participant | Conversation membership and Talk Turn logic | Use only where the selected person is already in a Conversation role. |
| SelectedPeerProjection | SelectedConversationProjection | App selected Conversation read model | Renamed first because it is a small derived projection; leaves broader state-machine names for later batches. |
| SelectedPeerSessionState | SelectedConversationProjectionState | App selected Conversation projection state | Renamed after backend readiness, Device PTT, and Connection facts were grouped under `BackendReadinessProjection`, `DevicePTTProjection`, and `ConnectionProjection`. |
| SelectedPeerCoordinator / SelectedPeerReducer | SelectedConversationCoordinator / SelectedConversationReducer | App selected Conversation reducer shell | Reducer events/effects/snapshots now use selected Conversation terminology. |
| SelectedPeerState | SelectedConversationState | App selected Conversation UI state | The selected contact's visible Beep/Conversation affordance state is about the selected Conversation, not a generic peer. |
| SelectedPeerPhase | SelectedConversationPhase | App selected Conversation UI phase | Diagnostics should emit `selectedConversationPhase`; keep old keys only for historical artifacts. |
| SelectedPeerDetail | SelectedConversationDetail | App selected Conversation UI phase payload | Carries state-specific payloads for the selected Conversation phase. |
| SelectedPeerWaitingReason | SelectedConversationWaitingReason | App selected Conversation convergence detail | Waiting reasons explain why the selected Conversation is not yet Ready or carrying Talk Turns. |
| SelectedPeerLocalSession | DevicePTTLocalSession | Device PTT boundary evidence | Keep `session` only because this is Apple/PTT device-boundary evidence; selected app state stores it under `DevicePTTProjection`. |
| SelectedPeerLocalSessionEvidence | DevicePTTLocalSessionEvidence | Device PTT boundary evidence payload | Names the joined/channel evidence inside `DevicePTTLocalSession`. |
| syncSelectedPeerSession | syncSelectedConversationProjection | App selected Conversation projection shell | Synchronizes selected Conversation projection inputs; not a product session. |
| requestJoinSelectedPeer / requestDisconnectSelectedPeer | requestJoinSelectedConversation / requestDisconnectSelectedConversation | App selected Conversation actions | Join/disconnect acts on the selected Conversation projection. |
| selected-peer-sync / selected-peer-effect | selected-conversation-sync / selected-conversation-effect | Diagnostics reason names | Preserve invariant IDs when predicates are unchanged; update reason/evidence names to selected Conversation terminology. |
| SelectedPeerSession.swift | SelectedConversationProjection.swift | App selected Conversation reducer/projection file | File name should match the projection/reducer it contains; keep historical handoffs unchanged. |
| selected-peer-prewarm / SelectedPeerPrewarm | selected-friend-prewarm / SelectedFriendPrewarm | App/backend selected Friend device hint | The hint is sent for a selected Friend before a Conversation is fully live; keep `peerDeviceID` in low-level delivery code for now. |
| SignalKind.SelectedPeerPrewarm | SignalKind.SelectedFriendPrewarm | Backend websocket signal kind | UCM backend should use selected Friend terminology for the pre-Conversation hint; current clients emit `selected-friend-prewarm`. |
| SelectedPeerEvidence / selectPeer | SelectedFriendEvidence / selectFriend | Engine selected Friend evidence | Engine selection names the selected Friend; keep peer/device terms only for low-level Connection and wire path concepts. |
| PeerReceiveAddressability / peerAddressability | ReceiverAddressability / receiverAddressability | Engine Talk Turn receiver evidence | Receiver means the Participant who would hear the local Talk Turn; keep `peerDeviceID` for backend/device boundary fields until that owner is refactored. |
| engine.transmit_requires_ready_peer | engine.transmit_requires_receiver_readiness | Engine Talk Turn precondition invariant | Local transmit requires receiver readiness evidence, not a generic ready peer. |
| channel.active_transmit_without_addressable_peer / ActiveTransmitHasAddressablePeer | channel.active_transmit_without_addressable_receiver / ActiveTransmitHasAddressableReceiver | Backend and TLA active Talk Turn invariant | Active transmit requires an addressable receiver, not a generic peer. |
| wake-capable peer / backendShowsWakeCapablePeerRecovery | wake-capable receiver / backendShowsWakeCapableReceiverRecovery | Selected Conversation wake recovery projection | The remote Friend is the receiver for the next Talk Turn; keep `peerDeviceConnected` and backend `wakeReadiness.peer` at their current boundary until that contract is refactored. |
| backendShowsConnectablePeerRecovery / routable peer evidence | backendShowsConnectableConversationRecovery / routable receiver evidence | Selected Conversation recovery and readiness tests | Backend evidence makes the selected Conversation connectable; Talk Turn routing evidence names the receiver. |
| sessionTransmitReady | connectionTransmitReady | Selected Conversation control-plane projection | The predicate says the Connection has enough remote/device evidence to carry Talk Turns; it is not a Device or API session. |
| peerSignalIsTransmitting / peerSignalTransmittingUpdated | remoteParticipantSignalIsTransmitting / remoteParticipantSignalTransmittingUpdated | Selected Conversation Talk Turn projection | The signal projects that the remote Conversation participant is taking a Talk Turn; backend wire `peer*` fields stay unchanged until their owner is refactored. |
| remoteReceiveProjectsPeerTalking | remoteReceiveProjectsRemoteTalkTurn | App receive projection helper | The helper checks whether receive execution currently projects a remote Talk Turn for the selected Friend. |
| selected.stale_membership_friend_ready_without_session | selected.stale_membership_friend_ready_without_local_device_ptt_evidence | Selected Conversation diagnostic invariant | The predicate is about missing local Device PTT evidence, not a generic session. |
| selected.backend_absent_with_live_session_evidence / selected.backend_idle_with_live_session_evidence | selected.backend_absent_with_local_device_ptt_evidence / selected.backend_idle_with_local_device_ptt_evidence | Selected Conversation diagnostic invariants | The predicates are about backend membership contradicting local Device PTT evidence, not generic live session evidence. |
| selected.backend_ready_missing_local_ptt_session | selected.backend_ready_missing_local_device_ptt_evidence | Selected Conversation diagnostic invariant | The predicate is about backend readiness without local Device PTT evidence or a join attempt, not a generic local PTT session. |
| selected.backend_absent_pending_local_action_without_session | selected.backend_absent_pending_local_action_without_device_ptt_evidence | Selected Conversation repair invariant | The predicate is about a pending local Device PTT action whose established Device PTT evidence is absent. |
| selected.stale_backend_membership_without_local_session | selected.stale_backend_membership_without_local_device_ptt_evidence | Selected Conversation diagnostic invariant | The predicate is about stale backend membership with no local Device PTT evidence. |
| selected.local_session_without_backend_presence / selected.local_session_without_backend_membership | selected.local_device_ptt_evidence_without_backend_presence / selected.local_device_ptt_evidence_without_backend_membership | Backend-sync recovery invariants | The local evidence is active Device PTT evidence; backend presence and membership are backend projections that must converge to it. |
| shouldRecover*ForActiveLocalSession / startBackendJoinRecoveryForActiveLocalSession | shouldRecover*ForActiveDevicePTTEvidence / startBackendJoinRecoveryForActiveDevicePTTEvidence | Backend-sync recovery helpers | These helpers recover backend presence/membership from active local Device PTT evidence, not a product/domain session. |
| localSessionEstablished / localSessionCleared | localDevicePTTEvidenceEstablished / localDevicePTTEvidenceCleared | Backend-sync contract and action reconciliation evidence | These booleans describe whether Device PTT evidence exists after a backend refresh. |
| LocalSessionDiagnosticsProjection / projection.localSession | DevicePTTDiagnosticsProjection / projection.devicePTT | Diagnostics selected Device projection | Diagnostics derive invariants from Device PTT evidence; true `systemSession` fields stay inside the Device boundary. |
| selected.reconciled_teardown_without_local_session | selected.reconciled_teardown_without_local_device_ptt_evidence | Merged diagnostics invariant | The predicate is about missing local Device PTT evidence during reconciled teardown, not a generic session. |
| SelectedConversationWaitingReason.localSessionTransition | SelectedConversationWaitingReason.devicePTTTransition | Selected Conversation waiting reason | This phase means Device PTT evidence is present while backend/connection projections converge. |
| shouldPreferBackendJoinReassertionForLiveSessionAfterSignalingDrift | shouldPreferBackendJoinReassertionForLocalConversationEvidenceAfterSignalingDrift | Backend signaling drift recovery helper | Reassertion is based on local Conversation evidence from Device PTT or TurboEngine, not a generic live session. |
| shouldPreserveLocalSessionAfterChannelRefreshFailure | hasLocalConversationEvidenceForChannelRefreshRecovery | Backend-sync recovery guard | The guard checks whether local Device PTT, engine Conversation, media, or transmit evidence should keep a backend Conversation alive through a transient channel refresh failure. |
| shouldPreserveLiveChannelState / effectiveChannelStatePreservingLiveMembership | shouldPreserveConversationStateDuringTransientMembershipDrift / effectiveChannelStatePreservingConversationMembership | Backend-sync membership preservation | These helpers preserve backend Conversation state or membership during transient backend drift; `ChannelState` remains only the backend route payload type. |
| clearLocalSessionAfterAuthoritativeChannelLoss | clearDevicePTTSessionAfterAuthoritativeChannelLoss | Device PTT teardown after backend authority | The teardown leaves Apple PushToTalk/system channel state after backend proves the channel is gone, so the Device PTT boundary should be named explicitly. |
| backendSyncStateAcceptsReadinessOlderThanLiveChannelStateEpoch | backendSyncStateAcceptsReadinessOlderThanReadyConversationStateEpoch | Backend-sync epoch regression test | The predicate is about readiness attached to a ready backend Conversation projection; the payload field remains `stateEpoch`. |
| liveSessionState / live_session_phases | connectedConversationState / ready_conversation_phases | Local projection and diagnostics variables | These locals classify connected or ready Conversation phases; they are not Device sessions or delivery sessions. |
| backendJoinNeedsLiveChannelSnapshot / liveJoinChannelSnapshot / live-join-channel-snapshot | backendJoinNeedsExistingConversationSnapshot / existingConversationSnapshot / existing-conversation-snapshot | Backend join command snapshot | Join-ready Friend handling may need the existing backend Conversation projection before choosing Beep-only versus join; `ChannelReadinessSnapshot` remains the backend route payload wrapper. |
| backendJoinExecutionPlan currentChannel parameter | backendJoinExecutionPlan existingConversationSnapshot parameter | Backend join command plan | The planner only needs the existing backend Conversation projection to decide whether a join-ready Friend can enter the Conversation; `ChannelReadinessSnapshot` remains the backend route payload wrapper. |
| contactsWithLiveChannels | contactsWithConversationChannels | Backend sync contact summary filter | Contact summaries retain cached backend Conversation projections only for contacts that still have backend channel IDs. |
| backend-signaling-drift:live-channel | backend-signaling-drift:backend-conversation | Backend signaling recovery source | The recovery branch is based on backend Conversation status, not a generic live channel. |
| BackendJoinExecutionPlan.joinSession | BackendJoinExecutionPlan.joinConversation | Backend join command plan | The plan chooses between creating/refreshing a Beep and joining the backend Conversation, not a generic session. |
| shouldRefreshBackendJoinSessionEvidenceBeforeJoin / refreshBackendJoinSessionEvidence | shouldRefreshBackendJoinConversationEvidenceBeforeJoin / refreshBackendJoinConversationEvidence | Backend join evidence refresh | Presence heartbeat refreshes backend Conversation evidence before a join; backend error text that says "device session" stays qualified as Device session. |
| shouldTreatBackendJoinDisconnectedSessionAsRecoverable | shouldTreatBackendJoinDisconnectedDeviceSessionAsRecoverable | Backend join error classifier | The backend error string is specifically `device session not connected`, so `Session` is allowed only with the Device qualifier. |
| BackendSessionConvergenceState | BackendConversationConvergenceState | Selected Conversation backend convergence | This state tracks backend join/readiness and control-plane convergence for the Conversation; it is not a runtime or Device session. |
| SelectedConversationWaitingReason.backendSessionTransition | SelectedConversationWaitingReason.backendConversationTransition | Selected Conversation waiting reason | The selected Conversation is waiting for backend Conversation/readiness convergence, not for a generic session object. |
| SessionReconciliationAction | SelectedConversationReconciliationAction | Selected Conversation reconciliation | Reconciliation chooses how to align backend Conversation truth, Device PTT evidence, and selected Conversation projection. |
| restoreLocalSession / teardownLocalSession | restoreDevicePTTSession / teardownDevicePTTSession | Selected Conversation reconciliation effects | The effects restore or tear down Device PTT state; `session` is allowed only with the Device PTT qualifier. |
| LocalSessionRestoreState / LocalSessionRestoreBarrier | DevicePTTRestoreState / DevicePTTRestoreBarrier | Device PTT automatic restore guard | Restore state and barriers belong to the Device PTT boundary, not generic product/session state. |
| session-teardown:* | device-ptt-teardown:* | Diagnostics reason names | Reconciled teardown clears Device PTT evidence after backend or selected Conversation authority changes. |
| session-disconnect:* | selected-conversation-disconnect:* | Diagnostics reason names | Explicit disconnect is a selected Conversation action that may leave backend and Device PTT state. |
| session-connect:* | selected-conversation-connect:* | Diagnostics reason names | Connect joins or requests the selected Conversation; it is not a generic session. |
| DurableSessionProjection / durableSessionProjection | DevicePTTContinuityProjection / devicePTTContinuityProjection | Selected Conversation Device PTT projection | This projection tracks local Device PTT continuity for the selected Conversation; it is not a generic durable session. |
| hadConnectedSessionContinuity | hadConnectedDevicePTTContinuity | Selected Conversation diagnostics and projection evidence | The sticky continuity evidence records that this Device previously had connected Device PTT continuity for the selected Conversation. |
| preservesConnectedSession | preservesConnectedDevicePTTContinuity | Local Talk Turn projection | Transmit start/stop phases preserve selected Conversation continuity because Device PTT is still connected or converging. |
| LocalSessionReadiness / localSessionReadiness | DevicePTTReadiness / devicePTTReadiness | Selected Conversation Device PTT readiness | The predicate says whether local Device PTT evidence is absent, partial, or aligned with the selected Conversation. |
| *WithoutLocalSessionEvidence | *WithoutDevicePTTEvidence | Selected Conversation backend/device contradiction predicates | These predicates compare backend Conversation truth with local Device PTT evidence, not a generic session. |
| pendingBackendConnectIsReadyForLocalRestore | pendingBackendConnectIsReadyForDevicePTTRestore | Selected Conversation restore predicate | Backend readiness can authorize restoring Device PTT for the selected Conversation. |
| backendMembershipCanRestoreMissingLocalSession | backendMembershipCanRestoreMissingDevicePTTEvidence | Selected Conversation restore predicate | Backend membership can restore missing Device PTT evidence when the backend Conversation still names this Device path. |
| localSessionEvidenceExists | devicePTTEvidenceExists | App selection and recovery guard | The helper checks Apple/system PTT and coordinator evidence for the contact, not a product session. |
| localSessionOrEngineConversationEvidenceExists | devicePTTOrEngineConversationEvidenceExists | App selection and recovery guard | Preserve selected Conversation continuity when either Device PTT evidence or engine Conversation evidence exists. |
| "End session and retry." | "End conversation and retry." | Product-facing recovery copy | User-visible recovery text should name the Conversation, not a generic session. |
| "Send Talk Request" / "Ask Again" / "Talk Requests" | "Send Beep" / "Beep Again" / "Beeps" | Product-facing Beep copy | The primary action and request sections should use Beep language, not generic talk-request wording. |
| "Ask Back" / allowsIncomingAskBack | "Beep Back" / allowsIncomingBeepBack | Product-facing offline incoming Beep response | Responding to an offline incoming Beep creates an outgoing Beep; keep that path in Beep terminology. |
| requestAgain / "Request Again" | beepAgain / "Beep Again" | App outgoing Beep refresh flow | Refreshing an existing outgoing Beep should use Beep language; command payloads may still carry `requestConnection`. |
| requestCooldown* | beepCooldown* | App outgoing Beep cooldown projection | Cooldown gates Beep Again for an outgoing Beep; keep `requestCount` because it is the backend Beep Thread counter field. |
| outgoing ask / incoming ask | outgoing Beep / incoming Beep | App Beep tests and diagnostics | Test names and diagnostics should describe Beep behavior; keep `BackendJoinRequest` and HTTP request terminology at command/API boundaries. |
| `declineRequest` / `cancelRequest` scenario actions and cancel/decline request diagnostics | `declineBeep` / `cancelBeep` and cancel/decline Beep diagnostics | Scenario DSL and selected Conversation Beep commands | These actions operate on a Beep, not a generic request. |
| request-only / `BackendJoinExecutionPlan.requestOnly` | Beep-only / `BackendJoinExecutionPlan.beepOnly` | Selected Conversation connect diagnostics and backend join planning | This projection/plan has only Beep evidence and must not be treated as joined Conversation evidence. |
| `ui.call_screen_visible_for_incoming_request` / `pair.pending_request_receiver_not_observed` | `ui.call_screen_visible_for_incoming_beep` / `pair.pending_outgoing_beep_receiver_not_observed` | Diagnostics invariant IDs | These predicates are about Beep behavior, so IDs should name Beep. Historical replay parsers may still accept old `incomingRequest` and `outgoingRequest` relationship strings. |
| `requestedCallFlapCandidate` | `outgoingBeepCallFlapCandidate` | App diagnostics invariant detector | The flap detector is scoped to `outgoingBeep`, not every UI request to expand a Call screen. |
| `requester` / `requesterRelationship` / `requesterObservedAt` evidence | `sender` / `senderRelationship` / `senderObservedAt` | Pair diagnostics evidence for pending outgoing Beeps | The device with an outgoing Beep is the Beep sender; use `receiver` for the Friend expected to observe the matching incoming Beep. |
| `ChannelStateStatus.IncomingRequest` / `ConversationState.incomingRequest` / `"incoming-request"` / `incomingRequest` scenario phase | `ChannelStateStatus.IncomingBeep` / `ConversationState.incomingBeep` / `"incoming-beep"` / `incomingBeep` scenario phase | Backend route, app projection, scenario status vocabulary | Incoming status values now name the incoming Beep directly. |
| IncomingInviteEvidence / invited | IncomingBeepEvidence / incomingBeep | Engine incoming Beep phase | Engine accept logic is gated by a Beep, not an invite. |
| EngineSessionPhase / engine.snapshot.session | EngineConversationPhase / engine.snapshot.conversation | TurboEngine Conversation truth | Engine owns local Conversation state; reserve session for Apple/PTT, URLSession, auth, and media runtime boundaries. |
| JoinedSessionEvidence | JoinedConversationEvidence | TurboEngine joined Conversation evidence | Joining a Conversation is domain truth; Device PTT/system sessions remain separate evidence. |
| SessionRecoveryEvidence / SessionRecoveryReason | ConversationRecoveryEvidence / ConversationRecoveryReason | TurboEngine Conversation recovery | Backend reconnect, transport recovery, and app foregrounding recover a Conversation projection, not a generic session. |
| syncEngineJoinedSession / backend-session / engineSession | syncEngineJoinedConversation / backend-conversation / engineConversation | App adapter bridge into TurboEngine Conversation truth | App diagnostics and bridge functions should name the engine Conversation; keep local/system session terms only for Device and Apple/PTT evidence. |
| seedEngineJoinedSessionForTesting / clearEngineSessionForTesting | seedEngineJoinedConversationForTesting / clearEngineConversationForTesting | Swift test helpers for engine Conversation truth | Test helpers should describe the engine domain state they seed or clear; Device/local media session helpers keep session wording. |
| engineJoinedSessionMatches / localOrEngineSessionEvidenceExists | engineJoinedConversationMatches / devicePTTOrEngineConversationEvidenceExists | App selected Conversation preservation guards | Preserve selected Conversation continuity from explicit Device PTT evidence or engine Conversation evidence. |
| existingSessionWasRoutable / RoutableReadySession | existingDevicePTTSessionWasRoutable / RoutableReadyDevicePTTSession | Backend readiness merge guard | The preserved evidence is local Apple PushToTalk/system-channel evidence, so `session` is allowed only when qualified as Device PTT. |
| selected.receiving_without_joined_session | selected.receiving_without_joined_conversation_evidence | Selected Conversation diagnostic invariant | The invariant is about a receiving projection without joined Conversation or Device PTT evidence, not a generic session. |
| selected.joined_session_lost_wake_capability | selected.joined_conversation_lost_wake_capability | Selected Conversation diagnostic invariant | The invariant is about a joined Conversation losing wake capability while Device PTT evidence is active. |
| pair.one_sided_*_session / pair.symmetric_peer_ready_without_session | pair.one_sided_*_conversation / pair.symmetric_friend_ready_without_device_ptt_evidence | Pair merged-diagnostics invariants | Pair diagnostics compare Conversation convergence; only Device PTT evidence keeps session-like wording. |
| refreshInvites / incoming-invites / outgoing-invites | refreshBeeps / incoming-beeps / outgoing-beeps | Simulator scenario DSL | Scenario specs should exercise Beep route projections with Beep names; app code already uses `refreshBeeps`. |
| `request_accept_ready*` / `request_cancel_before_accept` / `request_decline` / `simultaneous_request_conflict` | `beep_accept_ready*` / `beep_cancel_before_accept` / `beep_decline` / `simultaneous_beep_conflict` | Simulator scenario names | Scenario names should describe the Beep flow under proof, not generic request terminology. |
| `openPeer` / scenario action `"peer"` | `openFriend` / scenario action `"friend"` | Simulator scenario DSL relationship actions | Opening another person in the app is a Friend action. Keep `peer*` fields only for backend/device/readiness payloads where the boundary still uses peer terminology. |
| `BackendCommandOperation.openPeer` / `BackendCommandEvent.openPeerRequested` / `BackendCommandEffect.openPeer` / `openContact` lookup flow / "Add Contact" copy | `openFriend` / `openFriendRequested` / "Add Friend" | App backend-command relationship lookup path | Opening a handle in the app is selecting or resolving a Friend, not opening a peer transport. Keep the `Contact` model/storage names for a separate app-storage lane. |
| `DevSelfCheckStepID.peerLookup` / `peer-lookup` / "Peer lookup" | `friendLookup` / `friend-lookup` / "Friend lookup" | App diagnostics self-check step | The self-check resolves the selected Friend handle before backend/channel checks; Direct QUIC and media identity diagnostics may keep `peer identity` at their low-level boundary. |
| `presence_open_peer_projection` / `peer_disconnect_before_second_join` / `disconnect_clears_stale_peer_presence_during_state_refresh` | `presence_open_friend_projection` / `friend_disconnect_before_second_join` / `disconnect_clears_stale_friend_presence_during_state_refresh` | Simulator scenario names | Scenario names should use Friend for product/app relationship behavior. |
| SelectedSessionDiagnosticsSummary | SelectedConversationDiagnosticsSummary | Diagnostics selected Conversation payload | Diagnostics summarize the selected Conversation projection; keep local/system session names only for Device/PTT evidence. |
| projection.selectedSession | projection.selectedConversation | Structured diagnostics payload | Machine-readable diagnostics should expose the selected Conversation read model directly. |
| selectedPeer* diagnostics keys | selectedConversation* diagnostics keys | Diagnostics evidence fields | Preserve invariant IDs when predicate meaning is unchanged; evidence names should describe the selected Conversation projection. |
| selectedPeerBaseState / selectedPeer* test names | selectedConversationBaseState / selectedConversation* tests | App selected Conversation derivation and tests | The helper derives the selected Conversation base state; tests should describe the concept under proof, not the old peer-centric shell. |
| reconcileSelectedSession / teardownSelectedSession | reconcileSelectedConversation / teardownSelectedConversation | App selected Conversation reconciliation | These actions reconcile or tear down the selected Conversation projection; keep `systemSession` only for Apple/PTT device evidence. |
| TalkRequestSurface / IncomingTalkRequestSurface | IncomingBeepSurface | App foreground Beep presentation | The visible in-app surface represents an incoming Beep, not a separate talk-request concept. |
| TalkRequestNotificationIntent | BeepNotificationIntent | App notification/link intent parsing | Apple notification and intent adapters should translate payloads into Beep language immediately. |
| PTTViewModel+TalkRequests.swift | PTTViewModel+IncomingBeeps.swift | App incoming Beep surface and accept path | Accept/open/dismiss helpers should describe incoming Beeps; underlying HTTP/UNNotification request APIs keep their external names. |
| TalkRequestNotificationService target / `talk-request` APNs event / `TURBO_TALK_REQUEST` category | BeepNotificationService target / `beep` APNs event / `TURBO_BEEP` category | APNs notification service extension and backend alert payload | The APNs alert boundary now names the incoming Beep directly; no legacy payload compatibility is preserved before launch. |
| request.* foreground notification invariants | beep.* foreground notification invariants | App Beep notification diagnostics | These predicates are about Beep notification and surface behavior; backend Beep Thread invariants should be renamed separately. |
| request.* backend Beep invariants | beep.* / beep-thread.* backend invariants | Backend Beep and Beep Thread diagnostics | IDs should say `beep.*` for product Beep behavior and `beep-thread.*` for persisted Beep Thread storage rules. |
| requesterAutoJoinOnPeerAcceptance / requester shortcut / requester device | senderAutoJoinOnBeepAcceptance / sender shortcut / sender device | App shortcut projection and Beep tests | The shortcut belongs to the Friend who sent the Beep; acceptance is a Beep lifecycle event, not a peer/session concept. |
| PendingSessionAction / SessionCoordinatorState | PendingConversationAction / ConversationActionCoordinatorState | App pending Conversation action coordinator | This coordinator tracks app connect/join/leave work for a Conversation; real `systemSession` names stay in the Device PTT boundary. |
| PairRelationshipState / relationshipState(for:) | BeepThreadProjection / beepThreadProjection(for:) | App pending Beep projection | The selected/list app state projects pending incoming, outgoing, or mutual Beeps for a Friend; backend route payloads now expose `beepThreadProjection` too. |
| outgoingRequest / incomingRequest / mutualRequest cases | outgoingBeep / incomingBeep / mutualBeep cases | App pending Beep projection | Case names should say what is pending. |
| `ChannelStateStatus.Requested` / `ContactSummaryStatus.Requested` / `ConversationState.requested` / `TurboConversationStatus.requested` / `TurboSummaryBadgeStatus.requested` / `"requested"` / `requested` scenario phase / "Request sent" copy | `ChannelStateStatus.OutgoingBeep` / `ContactSummaryStatus.OutgoingBeep` / `ConversationState.outgoingBeep` / `TurboConversationStatus.outgoingBeep` / `TurboSummaryBadgeStatus.outgoingBeep` / `"outgoing-beep"` / `outgoingBeep` / "Beep sent" | Backend route, app projection, diagnostics, and scenario status vocabulary | Pending outgoing Beeps now name the Beep directly across backend and app projections. Existing backend rows may be reset; no pre-launch legacy compatibility is preserved. |
| RecentOutgoingRequestEvidence / OptimisticOutgoingRequestEvidence | RecentOutgoingBeepEvidence / OptimisticOutgoingBeepEvidence | App outgoing Beep acceptance evidence | These values preserve short-lived app evidence that an outgoing Beep was accepted or is being joined; backend wire request fields move in a backend route-shape lane. |
| pendingConnectAcceptedIncomingRequest / PendingConnectOrigin.acceptingIncomingRequest | pendingConnectAcceptedIncomingBeep / PendingConnectOrigin.acceptingIncomingBeep | App selected Conversation connection origin | The pending connection is caused by accepting an incoming Beep; backend and scenario incoming status now use incoming Beep terminology. |
| incomingRequestHandled / markIncomingRequestHandled | incomingBeepHandled / markIncomingBeepHandled | App incoming Beep local idempotence | Local bookkeeping records that a visible incoming Beep has already been acted on; notification/HTTP request terminology stays at external API boundaries. |
| joinAcceptedOutgoingRequest | joinAcceptedOutgoingBeep | App backend join intent | The join intent is an app-side Beep acceptance path, not a generic request concept. |
| RequestRelationship / requestRelationship | BeepThreadProjection / beepThreadProjection | Backend route projection | The backend projects pending Beep-thread direction as `beepThreadProjection`; `requestRelationship` is retired outside historical artifacts and scratch files. |
| hasIncomingRequest / hasOutgoingRequest | hasIncomingBeep / hasOutgoingBeep | Backend route direction flags | These booleans mirror the Beep Thread projection direction for compact route and diagnostics checks. |
| ActiveCallParticipantLease / ActiveCallParticipantPresenceEvidence / activeCallLeases | ActiveConversationParticipantLease / ActiveConversationParticipantPresenceEvidence / activeConversationParticipantLeases | Backend active Conversation participant lease predicate | This backend predicate proves active PTT Conversation participation, not an upgraded Call. |
| stateMembershipFromActiveLeases | stateMembershipFromActiveConversationParticipantLeases | Backend channel-state projection helper | The helper derives channel membership projection from active Conversation participant lease evidence, not a generic active lease. |
| CallPeerTelemetry / CallNetworkInterface / SignalKind.CallContext / "call-context" / activeCallContext* | ConversationParticipantTelemetry / ConversationNetworkInterface / SignalKind.ConversationParticipantTelemetry / "conversation-participant-telemetry" / conversationParticipantTelemetry* | App/backend Conversation participant telemetry signal | The payload carries one Participant's Device audio route and Connection network interface during a PTT Conversation; it is not an upgraded Call. |
| shouldPreserveSelectedSessionAfterAuthoritativeChannelLoss | shouldPreserveSelectedConversationAfterAuthoritativeChannelLoss | App selected Conversation convergence guard | The guard preserves selected Conversation continuity when authoritative backend channel data is transiently absent. |
| SystemPTTSessionState | DevicePTTProjection | Device boundary | Preserve Apple PushToTalk terminology where the boundary requires it; selected app state stores system PTT evidence under `DevicePTTProjection`. |
| ChannelReadinessSnapshot | BackendReadinessProjection | App selected Conversation backend projection | `ChannelReadinessSnapshot` remains the backend route payload snapshot; selected app state stores it under `BackendReadinessProjection` with convergence facts. |
| MediaConnectionState | ConnectionProjection | Delivery/media | Selected app state stores media state with Connection path and remote playback continuity under `ConnectionProjection`; use media qualification only when distinguishing audio from control-plane connection. |
| SelectedMediaTransportState | ConnectionProjection | Delivery/media | Keep transport terminology in low-level delivery shapes; selected app state exposes it as part of the Connection projection. |
| RemotePlaybackContinuityState | ConnectionProjection | Delivery/media | Remote playback continuity is one delivery input to Talk Turn readiness, not selected Conversation truth. |
| TransportPath | Connection Path | Delivery/media | Keep transport only in low-level networking and wire-path code. |

# Decision Test

A term is good when it helps a human explain the product and helps code avoid duplicate truth.

Before adding a new domain term, check:

- Does this concept already exist under a canonical name?
- Does the term describe a product/domain concept, a delivery detail, a Device detail, or an external API?
- Who owns the truth?
- What states or transitions does the term allow?
- Which existing names become deprecated if this term is accepted?
