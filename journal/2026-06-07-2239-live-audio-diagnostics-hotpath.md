# Journal 2026-06-07 22:39

## Summary

The latest physical evidence says the remaining intermittent word loss is receiver-local: packets arrive locally, then age inside app receive/admission before playback. This checkpoint keeps the current receive turn check off the heavy playback lock and adds a debug switch to disable live audio diagnostics on physical devices, so the next test can separate real media latency from diagnostics-induced hot-path pressure.

## Problem

- Symptom: after otherwise clean foreground Direct QUIC turns, `@bau -> @mau` sometimes played only the tail of the count, such as `7, 8, 9, 10`.
- Concrete invariant: `media.incoming_audio_queue_delay`.
- Evidence: the iPhone receiver reported `dropped-expired-live-backlog` with `localQueueDelayMs` over 1s for packets that had already reached the local app.
- Classification: app/audio hot path, not pure network loss. The receiver had packets; it processed them too late.

## Design formulation

- A current-turn receive packet must not wait for UI, diagnostics, ACK bookkeeping, route reporting, playback drain, or playback-lock work before admission.
- The receive epoch is small authoritative metadata. Reading it should never contend with the lock that protects playback scheduling and playout state.
- Per-packet diagnostics are useful only while debugging audio. They must be switchable because they can perturb the same timing they measure.
- The stale-live guard remains fail-closed. The fix is to prevent current speech from becoming stale, not to blindly play stale speech from an old semantic turn.

## What changed

- Added a separate receive-epoch lock and snapshot in `PCMWebSocketMediaSession`.
- Changed `currentRemoteAudioReceiveEpoch()` to read that snapshot instead of taking the playback lock.
- Added `TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled`.
- Added a Diagnostics UI toggle named `Live audio diagnostics`.
- Gated high-volume live receive, Direct QUIC incoming queue delay, ingress, chunk, drop, and Opus playout diagnostics behind that flag.
- Kept stale/expired drop handling active even when diagnostics are disabled, so repair behavior still runs.
- Added focused tests for the debug override and receive-epoch lock behavior.

## What worked

- The receive-epoch snapshot proof verifies packet admission can read the epoch even while the playback lock is held.
- The debug override tests verify the toggle works from stored preferences, launch arguments, and environment, and is ignored for production-like evaluation.
- Existing Direct QUIC receive proofs still pass: packet admission does not wait for MainActor work, and an Opus burst stays live without receive queue delay in the focused test lane.

## What not to repeat

- Do not solve local queue delay by increasing the stale-live window. That only hides the backlog and turns live speech into delayed playback.
- Do not leave per-packet diagnostics permanently authoritative in the hot path. Use them deliberately, then test with them off.
- Do not treat `media.incoming_audio_queue_delay` as network loss when the evidence includes local queue delay; it is app-side admission pressure until proven otherwise.

## Verification

```bash
just swift-test-target liveAudioDiagnosticsDebugOverrideSupportsStoredLaunchAndEnvironmentFlags
just swift-test-target liveAudioDiagnosticsDebugOverrideIsIgnoredForProductionLikeBuilds
just swift-test-target receiveEpochSnapshotDoesNotBlockBehindReceivePlaybackLock
just swift-test-target liveDirectQuicPacketAdmissionDoesNotWaitForMainActorPerPacketWork
just swift-test-target directQuicIncomingOpusBurstStaysLiveWithoutReceiveQueueDelay
```

## Next

1. Launch both physical devices and test foreground Direct QUIC with `Live audio diagnostics` off on both devices.
2. If the queue-delay invariant disappears and audio stays complete, keep live packet diagnostics off by default and only enable them for scoped audio debug sessions.
3. If word loss persists with diagnostics off, instrument the next seam with low-volume timing: local datagram arrival, receive executor admission, playback schedule, first audible playout, and drain.
4. Repeat the same A/B on Fast Relay after Direct QUIC foreground is stable.

## Files

- [`PCMWebSocketMediaSession.swift`](/Users/mau/Development/bb/client/ios/Turbo/PCMWebSocketMediaSession.swift)
- [`TurboBackendModels.swift`](/Users/mau/Development/bb/client/ios/Turbo/TurboBackendModels.swift)
- [`PTTViewModel+BackendSyncTransportFaultsAndSignals.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+BackendSyncTransportFaultsAndSignals.swift)
- [`PTTViewModel+DirectQuic.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+DirectQuic.swift)
- [`ContentViewDiagnostics.swift`](/Users/mau/Development/bb/client/ios/Turbo/ContentViewDiagnostics.swift)
- [`ConnectionTests.swift`](/Users/mau/Development/bb/client/ios/TurboTests/ConnectionTests.swift)
- [`DiagnosticsTests.swift`](/Users/mau/Development/bb/client/ios/TurboTests/DiagnosticsTests.swift)
