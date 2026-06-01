# Handoff 2026-05-28 15:23

## Summary

Turbo is in the first major terminology/projection wave of the whole-system semantic refactor. Rough progress against the full plan is about 20/100: the Beep/Friend vocabulary is now substantially clearer across app projections, scenario DSL, diagnostics, notification naming, tooling, one backend Conversation lease seam, and the Conversation Participant Telemetry signal. Backend model reset, selected projection restructuring, Connection/Talk Turn split, Device boundary isolation, and engine consolidation remain ahead.

Latest continuation: the app/backend signal batch for `CallContext` was applied and proofed. Live Unison `turbo/main` now uses `SignalKind.ConversationParticipantTelemetry` with wire tag `conversation-participant-telemetry`; Swift now uses `ConversationParticipantTelemetry` and `ConversationNetworkInterface`.

## Current truth

- `GLOSSARY.md` is the active terminology ledger for this refactor.
- Product/domain spine currently targeted: `Friend -> Beep -> Subject -> Ready -> Conversation -> Connection -> Device -> Talk Turn -> optional Call`.
- Incoming/outgoing Beep terminology is now active across Swift status enums, diagnostics invariant IDs, scenario phases, APNs alert naming, and simulator scenario names.
- Scenario relationship actions use `openFriend` with `friend`, not `openPeer` with `peer`.
- App backend-command relationship lookup uses `openFriend` / `openFriendRequested`; the underlying `Contact` model/storage names are intentionally left for a separate app-storage lane.
- Pair diagnostics evidence for pending outgoing Beeps now uses `sender`, `senderRelationship`, and `senderObservedAt` instead of `requester*`.
- Remaining `peer` terms in backend/readiness payloads, Direct QUIC, media identity, and device/wire evidence are intentional boundary terms unless a future owner-specific lane proves otherwise.
- `GLOSSARY.md` defines the backend internal term `Active Conversation Participant Lease` and records the rename from `ActiveCallParticipantLease` / `activeCallLeases` to `ActiveConversationParticipantLease` / `activeConversationParticipantLeases`.
- `GLOSSARY.md` also records `stateMembershipFromActiveLeases` -> `stateMembershipFromActiveConversationParticipantLeases`.
- `GLOSSARY.md` defines `Conversation Participant Telemetry` and records `CallPeerTelemetry` / `CallNetworkInterface` / `SignalKind.CallContext` / `"call-context"` / `activeCallContext*` -> `ConversationParticipantTelemetry` / `ConversationNetworkInterface` / `SignalKind.ConversationParticipantTelemetry` / `"conversation-participant-telemetry"` / `conversationParticipantTelemetry*`.
- Live Unison backend now uses the new Active Conversation Participant Lease names. MCP searches for `ActiveCall` and `activeCall` returned no live Unison results after the rename.
- Live Unison backend no longer has `SignalKind.CallContext`; MCP searches for `CallContext` and `call-context` returned no live results after the rename.

## What changed this session

- Continued the app-command Friend lane:
  - `BackendCommandOperation.openPeer` / event/effect names became `openFriend`.
  - `PTTViewModel.openContact(reference:)` became `openFriend(reference:)`.
  - add-friend UI copy now says `Add Friend` / `Opening friend...`.
  - `DevSelfCheckStepID.peerLookup` became `friendLookup`.
- Updated production replay conversion:
  - `scripts/convert_production_replay.py` now infers and emits `openFriend` actions with `friend`.
  - Generated replay proof emitted no `openPeer` or scenario `"peer"` action fields.
- Cleaned outgoing Beep projection wording:
  - Synthetic diagnostics/test status copy changed from `Request sent` to `Beep sent`.
  - Diagnostics/docs say Beep Thread relationship instead of request relationship where the concept is backend Beep state.
  - Invariant prose now says `outgoingBeep` / `incomingBeep` instead of old requested/incoming request wording.
- Cleaned sender terminology:
  - Pair merged diagnostics pending outgoing Beep evidence changed from `requester*` to `sender*`.
  - App/test names around sender shortcut and sender wake device no longer use requester wording.
  - `requestedCallFlapCandidate` became `outgoingBeepCallFlapCandidate`.
- Updated focused docs touched by these lanes: `GLOSSARY.md`, `SIMULATOR_FUZZING.md`, `STATE_MACHINE_TESTING.md`, `INVARIANTS.md`, `DESIGN.md`, and `diagrams.md`.
- Audited backend stale `Call` terminology:
  - Found live Unison definitions named `turbo.domain.ActiveCallParticipantLease`, `turbo.domain.ActiveCallParticipantPresenceEvidence`, `turbo.domain.activeCallParticipantLease*`, and `turbo.store.activeCallLeases.*`.
  - The source predicate is about durable membership plus matching channel presence plus connected Device session evidence for a PTT Conversation. It is not an upgraded Call.
  - Added the canonical internal glossary entry `Active Conversation Participant Lease`.
  - Added the ledger row mapping `ActiveCallParticipantLease / ActiveCallParticipantPresenceEvidence / activeCallLeases` to `ActiveConversationParticipantLease / ActiveConversationParticipantPresenceEvidence / activeConversationParticipantLeases`.
  - Applied Unison moves in `turbo/main`:
    - `turbo.domain.ActiveCallParticipantLease` -> `turbo.domain.ActiveConversationParticipantLease`
    - constructor `ActiveCallParticipantLease` -> `ActiveConversationParticipantLease`
    - `turbo.domain.ActiveCallParticipantPresenceEvidence` -> `turbo.domain.ActiveConversationParticipantPresenceEvidence`
    - `turbo.domain.activeCallParticipantLease*` -> `turbo.domain.activeConversationParticipantLease*`
    - `turbo.domain.activeCallParticipantPresenceEvidenceFromFacts` -> `turbo.domain.activeConversationParticipantPresenceEvidenceFromFacts`
    - `turbo.store.activeCallLeases` -> `turbo.store.activeConversationParticipantLeases`
    - `turbo.service.channels.internal.stateMembershipFromActiveLeases` -> `turbo.service.channels.internal.stateMembershipFromActiveConversationParticipantLeases`
  - Updated `invariants/registry.json` seam, detector, regression, predicate, and repair prose for `channel.active_projection_requires_participant_lease`.
- Refactored the app/backend Conversation Participant Telemetry signal:
  - Added the glossary entry and rename ledger row for `Conversation Participant Telemetry`.
  - Renamed Swift files:
    - `Turbo/CallPeerTelemetry.swift` -> `Turbo/ConversationParticipantTelemetry.swift`
    - `Turbo/PTTViewModel+CallTelemetry.swift` -> `Turbo/PTTViewModel+ConversationParticipantTelemetry.swift`
  - Renamed Swift types and helpers:
    - `CallPeerTelemetry` -> `ConversationParticipantTelemetry`
    - `CallNetworkInterface` -> `ConversationNetworkInterface`
    - `TurboSignalKind.callContext` -> `TurboSignalKind.conversationParticipantTelemetry`
    - `publishActiveCallContextIfNeeded` -> `publishConversationParticipantTelemetryIfNeeded`
    - `syncActiveCallTelemetryIfNeeded` -> `syncConversationParticipantTelemetryIfNeeded`
    - `currentLocalCallTelemetry` -> `currentLocalConversationParticipantTelemetry`
    - `applyPeerCallTelemetry` -> `applyRemoteConversationParticipantTelemetry`
    - `applyPeerCallContextPayload` -> `applyConversationParticipantTelemetryPayload`
    - local/published telemetry state dictionaries to `conversationParticipantTelemetry*` names
  - Renamed the backend signal constructor:
    - `turbo.domain.SignalKind.CallContext` -> `turbo.domain.SignalKind.ConversationParticipantTelemetry`
  - Updated backend `SignalKind.fromText` / `toText` to emit and accept `conversation-participant-telemetry`; the old `call-context` tag is rejected because there is no pre-launch legacy support requirement.
  - Updated `scripts/route_probe.py` to use `conversation-participant-telemetry`.
  - Updated focused backend-contract tests to the new signal/type names.
  - Updated `SWIFT.md` to point at `Turbo/ConversationParticipantTelemetry.swift`.

## What is not working

- No current blocker.
- The worktree is very large and dirty from several semantic-refactor lanes; do not treat `git status` as a single atomic change.
- `swift-format` is not installed in this environment; proof relies on compile/tests plus `git diff --check`.
- Backend model reset and persisted-shape cleanup have not started in this terminology handoff.
- The backend active participant lease rename is applied in Unison and `invariants/registry.json`; broader backend Beep Thread/Readiness/Device/Talk Turn reshaping is still pending.
- `Contact` remains the app storage/model term. Decide later whether to keep it as storage vocabulary or split it into a Friend-facing projection.
- Some legacy parser compatibility remains intentionally in diagnostics, e.g. relationship strings accepting `incomingRequest(` / `outgoingRequest(` for old reports.
- Historical handoffs, journal entries, and `tmp/` logs still contain old call-context text. Current app/backend source, current docs, route probe, and glossary target vocabulary use Conversation Participant Telemetry.

## Recommended next step

1. Resume broader backend terminology/model reset around Beep Thread, Readiness, Device, and Talk Turn.
2. Continue app-side terminology/projection cleanup where scoped, especially remaining `Contact` versus Friend/list projection terms and selected Conversation projection simplification.
3. After backend terminology is stable, resume selected Conversation projection cleanup and split stale `Contact`/Friend/list projection terms only where the owner is clear.

## Backend audit details

MCP project context was `turbo/main`.

Old Unison definitions that were renamed:

- `type turbo.domain.ActiveCallParticipantLease`
- `type turbo.domain.ActiveCallParticipantPresenceEvidence`
- `turbo.domain.activeCallParticipantLeaseDeviceId`
- `turbo.domain.activeCallParticipantLeaseLastSeenAt`
- `turbo.domain.activeCallParticipantLeaseSessionId`
- `turbo.domain.activeCallParticipantLeaseFromFacts`
- `turbo.domain.activeCallParticipantPresenceEvidenceFromFacts`
- `turbo.store.activeCallLeases.getForDevice`
- `turbo.store.activeCallLeases.getForUserInChannel`
- `turbo.store.activeCallLeases.hasForDevice`
- `turbo.store.activeCallLeases.hasForUserInChannel`
- `turbo.store.activeCallLeases.internal.bestForUserInChannel`
- `turbo.service.channels.internal.stateMembershipFromActiveLeases`

Important source shape:

```unison
type turbo.domain.ActiveCallParticipantLease =
  ActiveCallParticipantLease ChannelId UserId DeviceId Text Instant Instant

type turbo.domain.ActiveCallParticipantPresenceEvidence =
  FreshChannelPresence
  | RetainedChannelPresenceWithConnectedSession

turbo.domain.activeCallParticipantLeaseFromFacts durableMembership presenceEvidence connectedSession =
  durableMembership && connectedSession && isSome presenceEvidence
```

Known dependents from MCP:

- `turbo.service.channels.internal.sendTransmitPrepareIfTargetConnected`
- `turbo.service.channels.readiness`
- `turbo.service.channels.state`
- `turbo.service.channels.internal.peerSetupTargetDeviceId`
- `turbo.service.contacts.internal.summaryJson`
- `turbo.service.ws.internal.resolveEnvelopeTarget`
- `turbo.store.runtime.resolveTransmitTarget`
- `turbo.store.presence.isDeviceJoinedInChannel`
- `turbo.service.channels.beginTransmit`
- `turbo.service.channels.internal.joinControlCommandWithConnectedDevice`
- `turbo.service.contacts.internal.selfJoinedChannel`

Repo-side stale strings found by `rg -n 'ActiveCall|activeCall|CallParticipant|activeCallLeases|ConversationParticipantLease|activeConversationParticipant' .`:

- `invariants/registry.json` had `authoritativeSeam`, `detectors`, `regressions`, and repair prose using `activeCallLeases` / active call wording; this was updated.
- Several root `.u` scratch files contain historical `activeCall*` definitions. These are deleted/dirty scratch artifacts in this worktree and are not source of truth.
- The old Swift `activeCallContext*` / `CallPeerTelemetry` lane was later classified as Conversation Participant Telemetry and completed in the app/backend signal batch above.

Proofs from the completed backend lease microbatch:

```bash
# Unison MCP
run_tests turbo.domain.activeConversationParticipantLeaseFromFacts
run_tests turbo.domain.activeConversationParticipantPresenceEvidenceFromFacts
run_tests turbo.service.channels.internal.stateMembershipFromActiveConversationParticipantLeases
search ActiveCall
search activeCall
search activeCallLeases

# Shell
python3 -m json.tool invariants/registry.json >/dev/null
git diff --check
just backend-schema-drift-test
```

Results:

- Focused Unison tests passed.
- Unison name searches for old ActiveCall/activeCall/activeCallLeases names returned no live results.
- `invariants/registry.json` parses.
- `git diff --check` passed.
- `just backend-schema-drift-test` exited 0.

Proofs from the completed Conversation Participant Telemetry signal batch:

```bash
# Unison MCP
run_tests turbo.domain.SignalKind
run_tests turbo.service.ws.internal.signalAllowsMembershipOnlyAuthorization
run_tests turbo.service.ws.internal.signalUsesPreJoinDirectQuicSetupTarget
search CallContext
search call-context
search ConversationParticipantTelemetry

# Swift/app
python3 scripts/run_targeted_swift_tests.py \
  --name conversationParticipantTelemetryPublishesOnlyWhenTelemetryChanges \
  --name conversationParticipantTelemetryRepublishesUnchangedTelemetryAfterLivenessInterval \
  --name conversationParticipantTelemetryRepublishesSoonerWhileRemoteTelemetryIsMissing \
  --name incomingConversationParticipantTelemetrySignalUpdatesRemoteTelemetry

# Shell
python3 -m py_compile scripts/route_probe.py
git diff --check
just backend-schema-drift-test
```

Results:

- `turbo.domain.SignalKind` tests passed with new `conversation-participant-telemetry` wire tag and explicit old `call-context` rejection.
- Websocket signal authorization tests passed.
- Focused Swift backend-contract tests passed, executing 4 Swift Testing tests.
- `scripts/route_probe.py` compiles.
- `git diff --check` passed.
- `just backend-schema-drift-test` exited 0.

## Commands that matter

```bash
git diff --check
python3 scripts/test_merged_diagnostics.py
python3 -m py_compile scripts/merged_diagnostics.py scripts/test_merged_diagnostics.py scripts/convert_production_replay.py scripts/run_simulator_fuzz.py scripts/run_simulator_scenarios.py

python3 scripts/run_targeted_swift_tests.py \
  --name backendCommandReducerOpenFriendEmitsLookupEffect \
  --name scenarioActionDecodesOpenFriendActor \
  --name devSelfCheckRunnerSkipsFriendStepsWithoutSelection

python3 scripts/run_targeted_swift_tests.py \
  --name uiProjectionFlagsVisibleCallScreenForOutgoingBeep \
  --name diagnosticsExportIncludesOutgoingBeepCallFlapInvariant

python3 scripts/run_targeted_swift_tests.py \
  --name diagnosticsExportIncludesOutgoingBeepCallFlapInvariant \
  --name acceptedIncomingBeepTargetsWakeCapableSenderDevice \
  --name selectedConversationReducerAutoJoinsFriendReadyWhenSenderShortcutIsArmed \
  --name selectedConversationReducerDoesNotAutoJoinFriendReadyWhenSenderShortcutIsDisabled

rm -rf /tmp/turbo-production-replay-friend-proof
python3 scripts/convert_production_replay.py \
  --merged-diagnostics-json fixtures/production_replay/merged_diagnostics_pair_matrix.json \
  --output-dir /tmp/turbo-production-replay-friend-proof \
  --name fixture_production_replay_friend_terms
rg -n 'openPeer|"peer"\s*:|openFriend|"friend"\s*:' /tmp/turbo-production-replay-friend-proof

# Backend terminology audit scan used before stopping
rg -n 'ActiveCall|activeCall|CallParticipant|activeCallLeases|ConversationParticipantLease|activeConversationParticipant' .
```

## Files that matter

- [GLOSSARY.md](/Users/mau/Development/Turbo/GLOSSARY.md)
- [SWIFT.md](/Users/mau/Development/Turbo/SWIFT.md)
- [TESTING.md](/Users/mau/Development/Turbo/TESTING.md)
- [Turbo/BackendCommandCoordinator.swift](/Users/mau/Development/Turbo/Turbo/BackendCommandCoordinator.swift)
- [Turbo/PTTViewModel+BackendCommands.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+BackendCommands.swift)
- [Turbo/AppDiagnostics.swift](/Users/mau/Development/Turbo/Turbo/AppDiagnostics.swift)
- [Turbo/DevSelfCheck.swift](/Users/mau/Development/Turbo/Turbo/DevSelfCheck.swift)
- [scripts/merged_diagnostics.py](/Users/mau/Development/Turbo/scripts/merged_diagnostics.py)
- [scripts/convert_production_replay.py](/Users/mau/Development/Turbo/scripts/convert_production_replay.py)
- [scripts/test_merged_diagnostics.py](/Users/mau/Development/Turbo/scripts/test_merged_diagnostics.py)
- [invariants/registry.json](/Users/mau/Development/Turbo/invariants/registry.json)
- [TurboTests/BeepTests.swift](/Users/mau/Development/Turbo/TurboTests/BeepTests.swift)
- [TurboTests/ConversationTests.swift](/Users/mau/Development/Turbo/TurboTests/ConversationTests.swift)
- [TurboTests/DiagnosticsTests.swift](/Users/mau/Development/Turbo/TurboTests/DiagnosticsTests.swift)
- [TurboTests/ReadinessTests.swift](/Users/mau/Development/Turbo/TurboTests/ReadinessTests.swift)
- [TurboTests/SimulatorScenarioSupport.swift](/Users/mau/Development/Turbo/TurboTests/SimulatorScenarioSupport.swift)

## Notes

- Full plan progress estimate: about 20/100. The terminology base is real, but the structural simplification work is still mostly pending.
- Keep using small, independently proven lanes. Avoid broad mechanical replacements of `request`, `peer`, or `session`; many remaining uses are legitimate HTTP/protocol/device/Apple boundaries.
- Before broad backend searches, read `BACKEND.md`, `UNISON.md`, `TOOLING.md`, and `BACKEND_STRUCTURE.md`. Backend persisted-shape policy for this refactor is reset/abandon existing rows; no preserve migration is needed before launch.
