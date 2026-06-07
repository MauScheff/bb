# Journal 2026-06-07 23:10

## Summary

Foreground live audio is now stable on both Direct QUIC and Fast Relay packet lanes in physical iPhone/iPad testing with live audio diagnostics disabled. The remaining transport cells before broader state testing are foreground Fast Relay TCP fallback and foreground WebSocket fallback; media E2EE is still unavailable and intentionally deferred.

## Problem

- Direct QUIC and Fast Relay had regressed from smooth device audio to missing words, delayed receive queues, no-audio turns, and occasional stuck UI.
- The repeated diagnostic clue was `Media contract liveness failed: Incoming audio payload was delayed in the local receive queue`.
- Deep packet diagnostics and packet-only Fast Relay assumptions both distorted the live path: diagnostics increased hot-path pressure, and packet send success did not prove receiver playback.

## Design formulation

- Diagnostics controls belong in the debug-only Diagnostics surface. Production-like defaults should keep live packet diagnostics off.
- First playback ACK is the proof that a receiver heard current-turn audio; transport send completion is not enough.
- Packet lanes remain preferred, but standby continuity is valid until receiver playback is proven.
- Each transport cell should be proven independently before combining it with foreground/background state transitions.

## What changed

- Defaulted live audio diagnostics off.
- Kept high-volume packet metadata behind debug diagnostics controls.
- Reduced receive hot-path contention so diagnostics and UI work do not compete with live audio.
- Restored Direct QUIC packet behavior so unordered packet media is not treated like an ordered backlog.
- Added Fast Relay packet WebSocket continuity until first playback ACK proves receiver playback.
- Added focused Swift tests around packet standby, forced media relay packet continuity, TCP continuity, and ACK transport expectations.

## What worked

- Direct QUIC foreground-to-foreground became flawless in physical testing after live audio diagnostics were disabled.
- Forced Fast Relay foreground-to-foreground became very good after packet audio shadowed WebSocket continuity.
- User-reported physical result after the Fast Relay continuity build: "really really good now on the fast relay."

## What not to repeat

- Do not enable per-packet live diagnostics by default.
- Do not infer user-heard audio from packet send success.
- Do not move to foreground/background matrix testing until the foreground transport cells are independently clean.
- Do not treat E2EE absence as an audio reliability fix; it is a separate required release-quality task.

## Verification

```bash
git diff --check
just swift-test-target liveAudioDiagnosticsDefaultsOffForDebugBuilds
just swift-test-target productionBuildIgnoresLiveAudioDiagnosticsOverride
just swift-test-target forcedMediaRelayPacketShadowsWebSocketContinuityAfterPrewarmAck
just swift-test-target productionMediaRelayPacketStandbyShadowsWebSocketContinuity
just swift-test-target failedUnverifiedDirectQuicUsesStandbyMediaRelay
just swift-test-target productionMediaRelayPacketSendDoesNotNeedMainActorAfterFirstAckArm
just swift-test-target productionMediaRelayTcpContinuityDoesNotWaitForSlowRelaySend
just swift-test-target productionMediaRelayTcpStandbyShadowsWebSocketContinuity
just swift-test-target productionMediaRelayPacketStandbyUsesWebSocketUntilReceiverPrewarmAck
```

## Next

1. Test foreground-to-foreground WebSocket fallback.
2. Test foreground-to-foreground Fast Relay TCP fallback.
3. If both are clean, run the lane x app-state matrix: foreground/foreground, foreground/background, background/foreground, background/background.
4. Re-enable media end-to-end encryption for Direct QUIC and Fast Relay once transport reliability is stable.

## Files

- [`ContentViewDiagnostics.swift`](/Users/mau/Development/bb/client/ios/Turbo/ContentViewDiagnostics.swift)
- [`DiagnosticsSettings.swift`](/Users/mau/Development/bb/client/ios/Turbo/DiagnosticsSettings.swift)
- [`PTTViewModel+TransmitAudioSend.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+TransmitAudioSend.swift)
- [`PCMWebSocketMediaSession.swift`](/Users/mau/Development/bb/client/ios/Turbo/PCMWebSocketMediaSession.swift)
- [`ConnectionTests.swift`](/Users/mau/Development/bb/client/ios/TurboTests/ConnectionTests.swift)
