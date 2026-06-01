# Handoff 2026-05-16 16:46

## Summary

TestFlight run between `@mau` and `@ilki` exposed two separate problems: request/notification UI is treating durable requests as live connect affordances, and media path setup is being poisoned by stale peer device identity after reinstall/device-ID churn.

## Current truth

- Latest reliability intake artifact: `/tmp/turbo-reliability-intake/20260516-164241_mau__ilki`.
- Intake had 2 backend latest snapshots, 128 telemetry events, 0 source warnings, 0 current violations, 2 historical violations.
- `@mau` active TestFlight telemetry device was `785525eb-c99b-44c4-ac1d-1f013dda626b`.
- `@mau` old backend latest snapshot device was `1ef35829-981b-4ad4-8d94-bc830ab1828b`.
- `@ilki` repeatedly rejected Direct QUIC from `785525eb...` because expected peer device was `1ef35829...`.
- Media relay/Direct QUIC prewarm also repeatedly skipped on `@ilki` with `peer-device-missing`.
- User-facing request model agreed in discussion:
  - incoming request + peer online/connectable = live `Accept`/`Connect`
  - incoming request + peer offline = durable request, action should be `Ask Back`
  - background notification open should consume that notification surface; it should not also render a foreground banner
  - multiple foreground notifications should not stack; one active banner should update/represent the newest/count, with durable state in Inbox/contact rows.

## What changed this session

- Previous session already patched release/TestFlight to ignore stale persisted debug transport overrides in `Turbo/TurboBackendModels.swift`, with tests in `TurboTests/TurboTests.swift`.
- This handoff captures the request/notification quick fixes and the remaining media-device-identity work.

## Observed before quick fixes

- Foreground talk request banners can persist as live action surfaces even when the peer is offline.
- Contact detail can show enabled `Accept` for an incoming request even when the peer is offline; user wants `Ask Back`.
- Background notification open can also leave/show a foreground talk request banner for the same request.

## Original hard issue

- Harder media issue: peer device evidence can stay stale after reinstall/new device ID, causing Direct QUIC unexpected-peer rejection and media relay prejoin skips.
- Hypothesis: audio gaps and lingering “is talking” states in the latest run are downstream of stale device evidence plus backend/readiness convergence lag, but exact playback loss needs full same-window `@mau` media logs or a fresh shake.

## Hard fix implemented

- Backend connected-session evidence now requires a fresh session lease; a stale socket row alone no longer keeps an old device eligible as the active call peer.
- iOS now treats fresh, backend-routed Direct QUIC setup signals as current peer-device evidence, so an incoming request from a newly installed/current peer device can replace stale readiness evidence.
- iOS still preserves the trust boundary:
  - Direct QUIC setup requests must match envelope/payload/current device and the expected peer user.
  - Direct QUIC media offer/answer device evidence is recorded only after the backend peer fingerprint matches.
- Media relay ready-channel prejoin can use fresh peer-device evidence when readiness lacks `peerTargetDeviceId`.
- Deployed with `just deploy`; service hash `yggrw6flk55srdk5wpu7lpm2olhi4zuyl22tfn4zuzhudlo6vgna`.

## Recommended next step

1. Quick fixes: gate live foreground request banner and `Accept` action on peer online/connectable; use `Ask Back` for offline incoming requests.
2. Quick fixes: consume/suppress foreground banner when a background notification open selects/handles the same contact.
3. Retest the failed TestFlight cell between `@mau` and `@ilki`; if audio still drops, run fresh reliability intake and treat it as an audio/playback issue rather than the stale device-ID blocker.

## Quick fixes implemented

- Offline incoming requests now project the primary action as `Ask Back`, not `Accept`.
- Offline incoming requests no longer surface as live foreground request banners.
- Opening a background talk-request notification records the surfaced request key so the same request does not immediately show as a foreground banner.
- Backend join planning treats an offline incoming request as `requestOnly`; accepting/joining is reserved for online/connectable incoming requests.
- `performConnect` no longer queues a local call screen for offline incoming requests when backend services are available.

## Quick-fix proofs

```bash
just swift-test-target incomingRequestPrimaryActionUsesAskBackWhenPeerIsOffline
just swift-test-target incomingRequestPrimaryActionUsesAcceptLabel
just swift-test-target talkRequestSurfaceDoesNotShowOfflineIncomingRequestBanner
just swift-test-target backgroundNotificationOpenConsumesForegroundTalkRequestSurface
just swift-test-target offlineIncomingAskBackDoesNotQueueLocalConnect
just swift-test-target incomingAskStillQueuesLocalConnectForAccept
just swift-test-target backendJoinExecutionPlanTreatsOfflineIncomingInviteAsRequestOnly
just swift-test-target directQuicPeerDeviceIDPrefersFreshSignalEvidenceOverStaleReadiness
just swift-test-target selectedPrewarmRequestResendsActiveDirectQuicOffer
just swift-test-target directQuicProductionSignalAcceptsMatchingBackendPeerFingerprint
just swift-test-target directQuicProductionSignalRequiresMatchingBackendPeerFingerprint
just swift-test-target directQuicAutomaticProbeRequestsRemoteOfferForAnswererRole
```

## Commands that matter

```bash
just swift-test-target incomingRequestPrimaryActionUsesAskBackWhenPeerIsOffline
just swift-test-target talkRequestSurfaceDoesNotShowOfflineIncomingRequestBanner
just swift-test-target backgroundNotificationOpenConsumesForegroundTalkRequestSurface
just reliability-intake @mau @ilki
```

## Files that matter

- [TalkRequestSurface.swift](/Users/mau/Development/Turbo/Turbo/TalkRequestSurface.swift)
- [PTTViewModel+TalkRequests.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+TalkRequests.swift)
- [PTTViewModel+Notifications.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+Notifications.swift)
- [ConversationDomain.swift](/Users/mau/Development/Turbo/Turbo/ConversationDomain.swift)
- [TurboTests.swift](/Users/mau/Development/Turbo/TurboTests/TurboTests.swift)
- [intake-summary.md](/tmp/turbo-reliability-intake/20260516-164241_mau__ilki/intake-summary.md)
- [merged-diagnostics.txt](/tmp/turbo-reliability-intake/20260516-164241_mau__ilki/merged-diagnostics.txt)

## Notes

- Keep request UI and media-device reconciliation separate. The request fixes are client projection/UI semantics. The media problem is app/backend contract and device evidence ownership.
- Do not treat `incomingRequest` alone as a session claim. A call screen requires live peer readiness, an intentional pending join against a connectable peer, or an actual local/system session.
