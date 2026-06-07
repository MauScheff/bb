# Journal 2026-06-07 20:42

## Summary

Direct QUIC foreground audio is back to complete playback after moving live packet receive off the per-packet MainActor path and making packet playback truly detached from the receive actor. The latest physical checkpoint hears full 1-10 audio both ways. The remaining defect is asymmetric startup latency: `@mau -> @bau` starts almost immediately, while `@bau -> @mau` preserves a live receive backlog of roughly 1.7s before draining smoothly.

## Problem

- Physical test: `@mau` iPhone and `@bau` iPad, foreground-to-foreground, Direct QUIC.
- Good result: multiple back-and-forth turns counted 1 to 10 cleanly and stayed smooth.
- Earlier failure: after 2-3 clean turns, `@bau -> @mau` produced no audible audio on the iPhone.
- Invariant: `media.incoming_audio_queue_delay` on `@mau`.
- Evidence: intake `/tmp/turbo-reliability-intake/20260607-203355_mau__bau` reported Direct QUIC seq 319 preserved with `localQueueDelayMs=1955`, threshold `800`.
- Local device log showed the first packet of the failed turn accepted quickly: seq 153, `maxLocalQueueDelayMs=3`, ACK sent at `2026-06-07T18:26:29.190Z`.
- The same turn later backed up: seq 252/319 reached `maxLocalQueueDelayMs=1955`.
- At `2026-06-07T18:26:31.345Z`, the iPhone reported `Proximity state changed isNearEar=true`; at `18:26:31.529Z` it cleared the speaker override and switched to `Receiver`.
- Current checkpoint: `@mau -> @bau` and `@bau -> @mau` both play the whole count from 1 to 10.
- Current remaining failure: `@bau -> @mau` starts late by about 2s, then plays clearly and smoothly.
- Evidence: intake `/tmp/turbo-reliability-intake/20260607-204722_mau__bau` reported `media.incoming_audio_queue_delay` on `@mau`, Direct QUIC seq 1117, `receiveEpoch=10`, `localQueueDelayMs=1735`.
- The same checkpoint shows the first @mau receive ACK was fast: epoch started at `18:45:47.479Z`, first ACK and first accepted packet at `18:45:47.782Z` with `maxLocalQueueDelayMs=14`.
- The lag appears later in the same receive epoch: accepted count jumps from 22 to 72 while `maxLocalQueueDelayMs` rises to `1735`, then the preserved backlog drains. This is not packet absence; it is local live backlog preservation.

## Design formulation

- Direct/Fast packet media callbacks must be realtime admission inputs, not places where UI, diagnostics, route changes, ACK bookkeeping, or playback completion can accumulate.
- Each push-to-talk turn is semantically fresh. Old route changes, old playback drain, old diagnostics, and previous-turn post-admission work must not make the next live packet wait.
- Automatic proximity route switching is user-interface policy, not live media authority. It may update remembered proximity state during receive, but it must not mutate the AVAudioSession route while a remote turn is active or draining.
- Packet playback for unreliable lanes must run outside the receive actor. The receive actor may order/admit/drop, but it must not become the playback executor.
- A realtime receive queue should not preserve an expired live backlog as authoritative audio unless that is an explicit product choice. Preserving old live packets favors word completeness but converts a call into delayed playback; realtime speech needs a bounded live window with clear metrics for late drops, PLC, and catch-up.

## What Changed

- Added a nonisolated Direct QUIC packet handler that feeds `handleIncomingLiveAudioPayload` without rebuilding per-packet Direct attempt state on MainActor.
- Captured stable Direct receive identity (`channelID`, `fromUserID`, `fromDeviceID`) when activating the media path.
- Changed packet-media playback submission to use `Task.detached(priority: .userInitiated)` so playback and post-admission do not inherit the receive actor executor.
- Deferred automatic proximity route changes during any live receive phase: `prepared`, `awaitingFirstAudioChunk`, `receivingAudio`, or `drainingAudio`.
- Reconciled deferred automatic route state after remote receive/drain clears.
- Added regressions for Direct packet admission under MainActor blockage and proximity route deferral.

## What Worked

- Physical Direct QUIC testing became much smoother and faster; multiple turns played all numbers.
- The Direct hot-path proof caught a real design leak: one Direct packet could still stall while MainActor was blocked until packet playback was truly detached.
- The proximity route evidence explains why a turn can look like "no audio" even when packets are accepted and buffers are scheduled: playback can be routed to the earpiece mid-turn.
- The latest checkpoint proves the transport path is no longer the main failure: Direct QUIC delivers, ACKs are fast, and full speech plays. The remaining work is receiver-local latency policy, especially on the iPhone receive path.

## What Not To Repeat

- Do not tune SwiftNetEq or jitter buffering to compensate for local executor delay. A jitter buffer can absorb network timing, but it cannot fix app-side admission that happens two seconds after the datagram is already local.
- Do not let automatic audio-route policy mutate AVAudioSession during a live turn. Route changes belong between turns unless they are explicit user actions or required Apple/PTT activation.
- Do not use plain `Task {}` as a synonym for detached realtime work inside an actor. For packet media, inheriting actor context is exactly the failure mode.

## Verification

```bash
just reliability-intake @mau @bau
just device-diagnostics-connected /tmp/turbo-debug/20260607-203355-direct-receive-delay-latest
just reliability-intake @mau @bau
just device-diagnostics-connected /tmp/turbo-debug/20260607-iphone-receive-start-delay-checkpoint
just swift-test-target liveDirectQuicPacketAdmissionDoesNotWaitForMainActorPerPacketWork
just swift-test-target directQuicIncomingOpusBurstStaysLiveWithoutReceiveQueueDelay
just swift-test-target liveAudioReceiveExecutorAdmissionDoesNotWaitForSlowPacketPlayback
just swift-test-target automaticProximityRouteChangeIsDeferredDuringLiveReceive
```

## Next

1. Split @mau receive latency into explicit timings: transport arrival, receive executor admission, first playback ACK, first buffer scheduled, first non-silent scheduled buffer, and drain completion.
2. Decide the live backlog policy for Direct/Fast Relay: bounded realtime window with age-shedding and PLC, or delayed completeness. The product target is realtime, so stale live backlog should usually be dropped with metrics instead of preserved.
3. Promote `/tmp/turbo-reliability-intake/20260607-204722_mau__bau` into a Swift receive-stress replay for `receiveEpoch=10` so this latency cell can be tested without phones.
4. After Direct foreground startup latency is fixed, repeat the same matrix over Fast Relay, then lane upgrade/downgrade, then foreground/background cells.

## Files

- [`PTTViewModel+DirectQuic.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+DirectQuic.swift)
- [`PTTViewModelRuntime.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModelRuntime.swift)
- [`PTTViewModel+ProximityAudioRoute.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+ProximityAudioRoute.swift)
- [`PTTViewModel+BackendSync.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+BackendSync.swift)
- [`PTTViewModel+BackendSyncReceive.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+BackendSyncReceive.swift)
- [`ConnectionTests.swift`](/Users/mau/Development/bb/client/ios/TurboTests/ConnectionTests.swift)
