# Handoff 2026-06-06 23:18

## Summary

This handoff is for the next Turbo audio reliability pass after commit `391cf2c`. The repo is clean and pushed. Xcode Cloud TestFlight release has been started for the commit. Development-device audio is much better than earlier in the thread, but the remaining problem is a startup hitch under immediate speech and a newly observed direct/autolane flapping problem.

## Current truth

- Current branch: `main`.
- Current commit: `391cf2c Harden live audio receive scheduling`.
- Pushed to `origin/main`.
- Xcode Cloud build run: `059426a9-4447-4065-8d13-0559e98f8ebf`.
- A local artifact directory named `output_dir=/` was moved out of the checkout to `/tmp/turbo-debug/stashed-worktree-artifacts/output_dir-20260606T2115Z` so `just testflight` could run on a clean tree.
- The current physical devices are:
  - `@mau` iPhone: `00008030-0018786814D8802E`
  - `@bau` iPad: `00008103-001478421153001E`
- Debug-device test status: audio is generally good, but immediate speech still hitches near count `1/2`; waiting 2-3 seconds before counting hides it.
- New user observation: without forcing media relay, direct also sounds jagged and the lane flaps between direct, nothing visible, and media relay.

## What changed this session

- Live receive scheduling was made less main-actor dependent and more bounded.
- Production/default incoming live-audio admission for fast relay/direct was made serial and deterministic.
- Apple-gated held audio is flushed in media frame order when `VoicePacketV1`/Opus frame index is available.
- Parallel incoming admission remains available only as explicit test/config behavior.
- Media-core work from the previous agent is present: `SwiftNetEqPlayoutEngine`, `ShadowLegacyScheduledPlayoutEngine`, binary `VoicePacketV1`, and playout-engine mode selection.
- Focused tests were added/updated for receive ordering, Apple gating, burst admission, and bounded scheduling.
- A journal entry was created at `journal/2026-06-06-2318-live-audio-reliability.md`.

## What is not working

- Startup hitch remains in debug builds: immediate counting often plays the first number, stalls around the second, then catches up.
- TestFlight validation is not complete yet; the release workflow is running.
- Direct/autolane is now suspect. The user saw direct audio jagged, direct lane disappearing, and fallback to media relay on reply.
- It is still unknown whether the remaining hitch is mostly diagnostics load, Apple activation timing, SwiftNetEq startup gate behavior, lane transition churn, or a combination.

## Recommended next step

1. Wait for `just testflight` / Xcode Cloud run `059426a9-4447-4065-8d13-0559e98f8ebf` to finish, then have the user install TestFlight and run the same immediate-speech matrix.
2. Run three focused physical cells: forced fast relay, forced direct if available, and automatic lane. For each, record lane label changes, direction, missing numbers, and invariant text.
3. If automatic lane flaps, inspect lane transition diagnostics before touching playout. The question is whether audio startup is being interrupted by upgrade/downgrade/fallback rather than pure jitter.
4. If forced fast relay still hitches in TestFlight, instrument receive startup timing: Apple playback-ready, first packet admitted, first Opus frame decoded, first frame released by SwiftNetEq, first buffer scheduled.
5. Keep per-packet diagnostics behind an audio-debug flag; do not make them default release behavior.

## Commands that matter

```bash
git status --short
git log -1 --oneline
just testflight
just reliability-intake @mau @bau
just device-run 00008030-0018786814D8802E
just device-run 00008103-001478421153001E
just swift-test-target liveAudioReceiveExecutorFlushesAppleGatedPacketMediaInFrameOrder
just swift-test-target turboMediaRelayClientPreservesIncomingAudioOrderWhenFirstPayloadBlocks
```

## Files that matter

- `client/ios/Turbo/PTTViewModelRuntime.swift`
- `client/ios/Turbo/DirectQuicProbeController.swift`
- `client/ios/Turbo/PCMWebSocketMediaSession.swift`
- `client/ios/Turbo/VoiceMediaCodec.swift`
- `client/ios/TurboTests/ConnectionTests.swift`
- `docs/client/VOICE_MEDIA_CORE.md`
- `journal/2026-06-06-2318-live-audio-reliability.md`

## Notes

- Use `dev-debug`. Keep bulky logs under `/tmp/turbo-debug` and summarize only decisive evidence.
- The strongest current hypothesis is not "audio codec bad"; it is receive-turn startup ordering or lane transition churn.
- Do not assume every home-screen/minimize event is a crash unless Apple crash logs or device termination reports prove it.
