# Handoff 2026-06-07 23:10

## Summary

Foreground live audio is stable on Direct QUIC and Fast Relay packet media in physical iPhone/iPad testing. This handoff is for the next reliability cells: foreground WebSocket fallback, foreground Fast Relay TCP fallback, then the foreground/background matrix. Media E2EE remains unavailable and should be restored after transport reliability is stable.

## Current truth

- Direct QUIC foreground-to-foreground physical testing is clean with live audio diagnostics off.
- Fast Relay packet foreground-to-foreground physical testing is now "really really good" after adding WebSocket continuity until first playback ACK.
- Debug Diagnostics owns transport/diagnostic overrides.
- Production-like defaults should be Direct upgrade allowed, Fast Relay enabled but not forced, automatic control transport, packet metadata off, live audio diagnostics off.
- First playback ACK is the user-heard proof; packet send success is only transport evidence.

## What changed this session

- Defaulted live audio diagnostics off and made production-like builds ignore live-audio diagnostic overrides.
- Kept high-volume packet diagnostics behind the debug-only Diagnostics surface.
- Reduced receive hot-path contention and made live audio less dependent on MainActor-heavy diagnostics/UI work.
- Restored unordered packet semantics for Direct QUIC.
- Changed Fast Relay packet media to send WebSocket continuity until first playback ACK can prove receiver playback.
- Added focused Swift tests for live audio diagnostic defaults, packet/TCP continuity, standby behavior, and first-ACK expectations.
- Wrote journal entries for Direct QUIC diagnostics A/B and Fast Relay packet continuity.

## What is not working

- Media end-to-end encryption is currently unavailable on the tested Direct/Fast Relay paths.
- Foreground WebSocket fallback has not been revalidated after the recent media-core and scheduler changes.
- Foreground Fast Relay TCP fallback has not been physically revalidated.
- Foreground/background, background/foreground, and background/background cells have not been revalidated on this stable transport baseline.

## Recommended next step

1. Test foreground-to-foreground WebSocket fallback with live audio diagnostics off; count 1-10 both ways for 5-10 turns.
2. Test foreground-to-foreground Fast Relay TCP fallback with live audio diagnostics off; count 1-10 both ways for 5-10 turns.
3. If both pass, run the app-state matrix by lane: foreground/foreground, foreground/background, background/foreground, background/background.
4. After transport and app-state cells are stable, restore media E2EE for Direct QUIC and Fast Relay and rerun the smallest foreground smoke matrix.

## Commands that matter

```bash
just device-run-connected
just device-diagnostics-connected
just reliability-intake @mau @bau
just testflight
```

## Files that matter

- [`journal/2026-06-07-2245-direct-quic-diagnostics-ab.md`](/Users/mau/Development/bb/journal/2026-06-07-2245-direct-quic-diagnostics-ab.md)
- [`journal/2026-06-07-2307-fast-relay-packet-continuity.md`](/Users/mau/Development/bb/journal/2026-06-07-2307-fast-relay-packet-continuity.md)
- [`journal/2026-06-07-2310-direct-and-fast-relay-stable.md`](/Users/mau/Development/bb/journal/2026-06-07-2310-direct-and-fast-relay-stable.md)
- [`client/ios/Turbo/PTTViewModel+TransmitAudioSend.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+TransmitAudioSend.swift)
- [`client/ios/Turbo/PCMWebSocketMediaSession.swift`](/Users/mau/Development/bb/client/ios/Turbo/PCMWebSocketMediaSession.swift)
- [`client/ios/Turbo/DiagnosticsSettings.swift`](/Users/mau/Development/bb/client/ios/Turbo/DiagnosticsSettings.swift)
- [`client/ios/TurboTests/ConnectionTests.swift`](/Users/mau/Development/bb/client/ios/TurboTests/ConnectionTests.swift)

## Notes

- TestFlight/release builds must ignore persisted debug transport overrides from a previous development install.
- If WebSocket or TCP cells fail, classify whether the loss is ordered-backlog pressure, first-playback ACK absence, or Apple/PTT activation timing before patching.
- If packet lanes regress, first check whether live audio diagnostics or packet metadata were accidentally enabled.
