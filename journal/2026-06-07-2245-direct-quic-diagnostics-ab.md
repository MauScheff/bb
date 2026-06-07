# Journal 2026-06-07 22:45

## Summary

Foreground Direct QUIC became flawless after disabling live audio diagnostics on both physical devices. The physical A/B result strongly suggests the remaining intermittent word loss was not caused by Direct QUIC delivery, SwiftNetEq playout, or a generic device/network failure; it was receiver-local hot-path pressure, with high-volume diagnostics perturbing the same timing they were measuring.

## Problem

- Before this checkpoint, `@bau -> @mau` sometimes played only the tail of speech, such as `7, 8, 9, 10`.
- Diagnostics repeatedly reported `media.incoming_audio_queue_delay`.
- The important evidence was `localQueueDelayMs` above 1s for packets already inside the receiving app.
- After the new build, the user turned `Live audio diagnostics` off and tested five foreground Direct QUIC back-and-forth runs.
- Result: all five runs were flawless both ways.

## What we found out

- Direct QUIC itself can produce perfect, low-latency audio in the current app.
- The media receive path is sensitive to extra work around packet admission, especially on the receiver side.
- The queue-delay invariant was correctly detecting app-side delay, not network loss.
- Per-packet live diagnostics can be too invasive for physical audio testing. They are useful when investigating a failure, but they must not be treated as free.
- Turning diagnostics off did not require changing the media protocol, lane selection, or SwiftNetEq policy, which makes diagnostics pressure the best current explanation for the intermittent word loss.
- The stale-live guard remains valuable: it tells us when current speech became stale locally. The product fix is to prevent the delay, not to widen the stale window and play old speech.
- TestFlight and production still need diagnostics, but not live packet diagnostics by default. Their useful signal is control-plane, lane state, lifecycle, and shake-report context; live audio packet diagnostics are a scoped Debug-only tool.

## Design formulation

- Live media work has priority over observability. Diagnostics must never be able to make a current speech turn late.
- High-volume audio diagnostics belong behind an explicit Debug switch and should default off for realistic physical audio quality testing.
- Release/TestFlight builds must not allow stored preferences, launch arguments, or environment variables to enable live audio diagnostics.
- Production telemetry should prefer low-volume summaries, sampled counters, and post-turn aggregation over per-packet hot-path recording.
- A clean physical A/B is more authoritative than reading more noisy packet logs once the invariant already points to local queue delay.

## What changed

- Prior commit `55074e5` added a separate receive-epoch snapshot lock, removing one playback-lock dependency from packet admission.
- Prior commit `55074e5` added the `Live audio diagnostics` toggle.
- Prior commit `55074e5` gated high-volume receive, ingress, drop, queue-delay, and Opus playout diagnostics behind that toggle.
- This entry records the first successful physical Direct QUIC A/B result with that toggle off.
- Follow-up policy change: live audio diagnostics now default off even in Debug, and remain impossible to enable in production-like builds.

## What worked

- Five foreground Direct QUIC back-and-forth physical runs were flawless after disabling live audio diagnostics.
- This confirms the next reliability strategy: keep the media hot path lean, then reintroduce observability as bounded, sampled, or post-turn work.

## What not to repeat

- Do not debug audio quality with all live packet diagnostics enabled and then assume that result represents production behavior.
- Do not compensate for diagnostics-induced queue delay inside the jitter buffer or lane machine.
- Do not conflate `media.incoming_audio_queue_delay` with lane failure when the lane is Direct QUIC and packets are already local.

## Verification

```bash
just device-run-connected
# Manual physical test:
# 1. Disable Live audio diagnostics on @mau and @bau.
# 2. Keep Audio packet metadata off.
# 3. Test foreground Direct QUIC both ways.
# 4. Run five back-and-forth count-to-10 turns.
# Result: flawless audio both ways.
```

## Next

1. Test Fast Relay with the same controls: `Live audio diagnostics` off, `Audio packet metadata` off, foreground-to-foreground, five to ten back-and-forth turns.
2. If Fast Relay is flawless, keep this as the baseline for the lane matrix.
3. If Fast Relay loses audio while Direct QUIC remains flawless, classify it as a Fast Relay transport/admission issue, not a general playout issue.
4. After Direct QUIC and Fast Relay are stable foreground-to-foreground, test foreground/background combinations.

## Files

- [`journal/2026-06-07-2239-live-audio-diagnostics-hotpath.md`](/Users/mau/Development/bb/journal/2026-06-07-2239-live-audio-diagnostics-hotpath.md)
- [`PCMWebSocketMediaSession.swift`](/Users/mau/Development/bb/client/ios/Turbo/PCMWebSocketMediaSession.swift)
- [`PTTViewModel+BackendSyncTransportFaultsAndSignals.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+BackendSyncTransportFaultsAndSignals.swift)
- [`PTTViewModel+DirectQuic.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+DirectQuic.swift)
- [`ContentViewDiagnostics.swift`](/Users/mau/Development/bb/client/ios/Turbo/ContentViewDiagnostics.swift)
