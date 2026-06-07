# Journal 2026-06-07 23:07

## Summary

Forced Fast Relay packet audio can report local packet delivery without proving that the receiver played user-heard audio. First playback ACK remains the user-heard proof, so packet Fast Relay now carries immediate WebSocket continuity until receiver playback is proven.

## Problem

- Physical foreground Fast Relay test produced no audio on the receiver.
- Sender logged `Timed out waiting for first audio playback ACK`.
- Diagnostics showed `media-relay-packet` was the armed/delivered transport, but the receiver only scheduled playback and sent ACK after WebSocket continuity arrived.

## Design formulation

- Packet delivery is transport evidence, not playback evidence.
- First playback ACK is the liveness proof for the current turn.
- Fast Relay packet media stays preferred, but unproven packet lanes must not be the sole user-heard path.
- WebSocket continuity is allowed as a standby copy until a current playback ACK arrives. Receiver duplicate and stale-payload handling remains responsible for avoiding double playback.

## What changed

- Forced Fast Relay packet sends now arm first-playback ACKs for both `media-relay-packet` and `relay-websocket`.
- Dynamic Fast Relay packet standby now shadows WebSocket continuity, matching the existing degraded TCP continuity policy.
- Focused tests were updated to encode the new invariant: packet media may be sent, but continuity is expected until playback proof exists.

## What worked

- Direct QUIC became flawless when live audio diagnostics were disabled, confirming that per-packet diagnostics can perturb live audio and should remain debug-only.
- The Fast Relay no-audio run localized to an unproven packet lane, not SwiftNetEq playout or Direct QUIC.
- The focused Swift tests now prove both forced and dynamic Fast Relay packet paths keep a continuity route available.

## What not to repeat

- Do not treat a successful packet send as sufficient evidence that the receiver heard audio.
- Do not remove standby continuity from packet lanes until packet relay ingress, receiver delivery, and playback ACKs are proven across the physical matrix.
- Do not enable live packet diagnostics by default; diagnostics controls belong in the debug-only Diagnostics surface.

## Verification

```bash
git diff --check
just swift-test-target forcedMediaRelayPacketShadowsWebSocketContinuityAfterPrewarmAck
just swift-test-target productionMediaRelayPacketStandbyShadowsWebSocketContinuity
just swift-test-target failedUnverifiedDirectQuicUsesStandbyMediaRelay
just swift-test-target productionMediaRelayPacketSendDoesNotNeedMainActorAfterFirstAckArm
just swift-test-target productionMediaRelayTcpContinuityDoesNotWaitForSlowRelaySend
just swift-test-target productionMediaRelayTcpStandbyShadowsWebSocketContinuity
just swift-test-target productionMediaRelayPacketStandbyUsesWebSocketUntilReceiverPrewarmAck
```

## Next

1. Relaunch iPhone and iPad, force Fast Relay, keep live audio diagnostics off, and retest foreground-to-foreground 5-10 back-and-forth turns.
2. If Fast Relay still has silence or slow startup, check whether the receiver ACK arrives via `relay-websocket`; if not, make the continuity copy concurrent with packet send and inspect relay ingress/delivery timing.

## Files

- [`PTTViewModel+TransmitAudioSend.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+TransmitAudioSend.swift)
- [`ConnectionTests.swift`](/Users/mau/Development/bb/client/ios/TurboTests/ConnectionTests.swift)
