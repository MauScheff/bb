# Journal 2026-06-06 23:18

## Summary

We moved the live-audio debugging loop from repeated physical-device patching toward bounded receive scheduling, algebraic playout, and release-quality validation. Fast relay became more stable after making receive admission deterministic and non-main-authoritative, but the remaining startup hitch and the latest direct-QUIC flapping show that the next owner is likely the lane-selection/activation boundary plus receiver startup scheduling under lighter diagnostics, not only the fast-relay transport.

## Problem

- Physical tests between `@mau`, `@bau`, `@ilki`, and TestFlight builds showed app exits/minimization, poor audio, lost numbers, delayed receive queues, and stuck receiver UI.
- The recurring diagnostic phrases were `media: contract liveness failed, incoming audio payload was delayed in the local receive queue`, `opus playout buffer updated`, `dropped stale outbound audio transport payload`, and PTT activation/participant-clear failures.
- The failure was worst during rapid back-and-forth turns, usually not on the first turn. Waiting between turns reduced the issue, suggesting backlog, scheduler pressure, or activation ordering rather than a simple codec failure.
- The latest remaining fast-relay symptom is a startup hitch: immediate speech plays `1`, stalls around `2`, then catches up. Waiting 2-3 seconds before speaking hides it.
- A new observation on the same debug build without forced media relay: direct audio is also jagged, and the route flaps between `direct`, no visible lane, and media relay. That may be the same root through lane upgrade/downgrade, or a second bug in autolane fallback.

## Design formulation

- Apple/PTT and UI belong on the main actor; live audio, transport ingress, playout scheduling, and diagnostics must be bounded and mostly off-main.
- Each talk turn should be semantically fresh: stale packets from older receive/transmit epochs must be discarded, not allowed to affect later turns.
- Receiver queues must be bounded. Queue pressure should drop, summarize, or defer nonessential work before it blocks control convergence or active audio.
- Packet ordering must be based on media identity when available. Transport sequence and task resume order are not authoritative for playout frame order.
- A lane change is a state-machine transition, not a side effect. Direct, fast relay, and relay need observable transition reasons and bounded fallback rules before trusting audio symptoms.

## What changed

- Added and plugged a modular media core slice around `VoicePlayoutEngine`, including `SwiftNetEqPlayoutEngine`, `ShadowLegacyScheduledPlayoutEngine`, binary `VoicePacketV1` framing, and mode selection through `VoiceMediaCoreMode`.
- Removed the legacy PCM path as authoritative for current media-core behavior and moved toward binary Opus packet handling at the existing transport boundary.
- Reworked live receive scheduling so diagnostics and receive bookkeeping are lower priority than active media.
- Made fast-relay/direct incoming live-audio admission deterministic by default: incoming handlers are serial for production defaults, while tests can still opt into parallel admission.
- Changed Apple-gated startup burst flushing to sort by audio frame index when available instead of transport sequence alone.
- Added focused Swift tests for packet framing, playout-engine selection, receive-ordering under Apple gating, queue behavior, and fast-relay/direct burst admission.
- Committed and pushed the reliability checkpoint as `391cf2c Harden live audio receive scheduling`.
- Started Xcode Cloud TestFlight release workflow for commit `391cf2ce690693aba0091792ceafdddc597e0921`; build run `059426a9-4447-4065-8d13-0559e98f8ebf`.

## What worked

- Direct device development testing improved from frequent stuck receivers/no audio to mostly complete, clean audio with a consistent startup hitch.
- Serial admission plus media-frame ordering directly addresses the observed held-burst disorder where packets were local and Apple activation was open, but early playout starved on a missing/reordered frame.
- Bounded receive scheduling reduced long receiver freezes and made failures sharper: the remaining issue now looks like startup activation/lane scheduling rather than unbounded accumulation.
- Physical tests with short waits before speaking generally sound clean, which strongly suggests the steady-state playout path is close and the remaining problem is at receive-turn startup.

## What not to repeat

- Do not fix the startup hitch by immediately concealing every missing early frame. That was tried and caused stutter across the whole utterance.
- Do not keep adding per-packet diagnostics on the hot path as the default. Per-packet diagnostics are useful only when explicitly debugging audio and can perturb the very timing being tested.
- Do not assume fast relay is the only owner. The latest direct-QUIC test also showed jagged audio and lane flapping, so autolane transition behavior must be inspected.
- Do not treat iOS returning to the home screen as a confirmed crash without crash logs. Earlier evidence suggested at least some events were Apple/PTT lifecycle or resign-active behavior, not process death.

## Verification

```bash
just swift-test-target liveAudioReceiveExecutorFlushesAppleGatedPacketMediaInFrameOrder
just swift-test-target liveAudioReceiveExecutorFlushesAppleGatedPacketMediaInSequenceOrder
just swift-test-target turboMediaRelayClientPreservesIncomingAudioOrderWhenFirstPayloadBlocks
just swift-test-target directQuicProbeControllerCanAdmitIncomingAudioBurstWhenConfiguredForParallelHandlers
just swift-test-target mediaRelayPromotionHandshakeTimeoutIsBounded
just swift-test-target turboMediaRelayDatagramBurstDoesNotExpireWhileAppleGateHoldsParallelHandlers
git diff --check
git commit -m "Harden live audio receive scheduling"
git push origin main
just testflight
```

## Next

1. Let the Xcode Cloud TestFlight build complete, then run the same immediate-speech test on TestFlight to compare against debug diagnostics load.
2. Investigate autolane/direct-QUIC flapping with focused diagnostics: direct-only, fast-relay-only, and automatic lane modes should produce explicit lane transition reasons.
3. If TestFlight still hitches on startup, instrument the receive-turn startup timeline around Apple playback-ready, first decoded Opus frame, SwiftNetEq startup gate, first scheduled buffer, and first audible sample.
4. Keep per-packet diagnostics disabled by default unless an audio-debug flag is explicitly enabled.

## Files

- `client/ios/Turbo/PTTViewModelRuntime.swift`
- `client/ios/Turbo/DirectQuicProbeController.swift`
- `client/ios/Turbo/VoiceMediaCodec.swift`
- `client/ios/Turbo/PCMWebSocketMediaSession.swift`
- `client/ios/TurboTests/ConnectionTests.swift`
- `client/ios/TurboTests/AudioFuzzTests.swift`
- `docs/client/VOICE_MEDIA_CORE.md`
- `docs/client/SWIFT.md`
