# Journal 2026-06-07 22:20

## Summary

During direct/relay physical-device testing, the iPhone appeared to disappear to the home screen. The evidence does not look like a normal Swift crash: the launched iPhone process exited, Apple/PTT relaunched BeepBeep in the background, and the app handled a restored stale PTT channel followed by a `leave-channel` push. Keep this as an Apple/PTT lifecycle boundary issue until we prove otherwise.

## Problem

- Symptom: the app appears to minimize or vanish to the home screen during or immediately after a call attempt.
- Context: physical-device testing between `@mau` on iPhone and `@bau` on iPad, after repeated call/audio iterations.
- Concrete evidence:
  - Launch created iPhone process PID `57859`.
  - Later process listing showed BeepBeep running as PID `57871`, so the original process did exit or was terminated.
  - Pulled crash logs contained no BeepBeep `.ips`; only unrelated old crash files were present.
  - The app diagnostics showed `Initializing app` while `UIApplicationState(rawValue: 2)`, then Apple restored a mismatched PTT channel, then the app returned `leaveChannel` for a `leave-channel` push.

## Design formulation

- Apple/PTT channel restoration is a device-boundary input, not app truth.
- A restored PTT channel has authority only if it matches the current backend channel, selected conversation, and live app session evidence.
- A mismatched restored PTT channel must be quarantined and left idempotently without rehydrating a call, starting live audio, or forcing the foreground UI into a stale call.
- If iOS terminates and relaunches the app for PTT cleanup, the app should converge to idle safely; if iOS repeatedly terminates us, we need system-level evidence such as sysdiagnose, because app diagnostics cannot explain the termination cause after the process is gone.

## What changed

- No code changed in this journal entry.
- Captured the current evidence and hypothesis so the issue stays separate from the receive queue/audio playout debugging.

## What worked

- App diagnostics were enough to distinguish a background PTT restoration path from a visible Swift exception.
- Process listing confirmed the app was relaunched under a new PID.
- Crash-log pull did not show a BeepBeep crash report, which makes a normal app crash less likely.

## What not to repeat

- Do not classify the home-screen disappearance as a regular crash unless a BeepBeep `.ips`, exception log, or fatal app diagnostic appears.
- Do not merge this into the audio receive queue bug without evidence; stale PTT restoration can be triggered around the same call attempts but is a different boundary.
- Do not let a restored Apple PTT channel re-authorize live call state without backend/session matching evidence.

## Verification

```bash
just device-diagnostics-crash-logs 5A6E1B5A-1E8C-5D98-A6D5-7D342562E977 /tmp/turbo-device-disappear-iphone
xcrun devicectl device info processes --device 5A6E1B5A-1E8C-5D98-A6D5-7D342562E977 --json-output /tmp/turbo-device-disappear-process/iphone-processes.json
rg -n "Initializing app|PTT restored channel|Quarantined restored|Incoming PTT push|Returning incoming PTT push|Left channel|UIApplicationState" /tmp/turbo-device-disappear-iphone/app-diagnostics/beepbeep-diagnostics.log
```

## Next

1. Retest on freshly launched devices and watch whether the home-screen disappearance repeats.
2. If it repeats without a BeepBeep `.ips`, collect sysdiagnose or a tighter OS log window to identify the iOS termination reason.
3. Add or keep a Swift adapter proof for stale restored PTT channel interleavings: restore, join callback, leave push, app background, backend idle, and mismatched channel.

## Files

- [`journal/2026-06-07-2220-ptt-background-restoration.md`](/Users/mau/Development/bb/journal/2026-06-07-2220-ptt-background-restoration.md)
