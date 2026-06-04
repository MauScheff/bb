# Handoff 2026-06-04 09:35

## Summary

TestFlight physical-device report from June 4, 2026: during a call between `@mau` and `@ilki`, the `@mau` app was killed/exited shortly after holding the talk button. About two seconds of audio was heard before termination, reverse-direction audio was poor/missing, and expected call-screen statistics were not visible.

## Current truth

- Connected `@mau` device reported installed BeepBeep `1.0 (169)` via `devicectl`.
- Backend latest diagnostics for exact current devices were missing, so autopublish did not capture the failed call.
- App Store Connect/Xcode Organizer showed a crash for build `167`, not build `169`.
- The build `167` stack points at `AudioChunkSender.waitForInFlightSendProgress`, line 363, while reading `inFlightSends`.
- Commit `e308cb8` changed `AudioChunkSender` task lifetime by moving send tasks out of `InFlightTransportSend` and into `inFlightSendTasks`; this may already address the build `167` crash if build `167` predates that commit.
- `CURRENT_PROJECT_VERSION` is `169` in `client/ios/Turbo.xcodeproj/project.pbxproj`.

## What Changed This Session

- `client/ios/Turbo/Info.plist` now explicitly emits `CFBundleShortVersionString` and `CFBundleVersion`.
- `TurboCallScreenStatisticsVisibilityFlag` now checks the real bundle `appStoreReceiptURL` by default, so TestFlight call statistics are enabled when the receipt path is `sandboxReceipt`.
- `PCMWebSocketMediaSession.state` now uses `stateLock` for reads and writes instead of unsafely accessing mutable state from audio/async paths.
- `tools/scripts/device_app.py` crash-log capture now continues after a partial nonzero `devicectl` system crash-log copy, writing `crash-logs-copy-warning.txt` instead of failing the whole diagnostics capture.
- Added focused tests for the TestFlight statistics flag and partial crash-log capture.

## What Is Not Working

- The June 4 build `169` app kill does not currently have a visible TestFlight crash report.
- Exact-device backend diagnostics were unavailable for `@mau/56febd70-2863-4c6d-af4d-9d67c6bc0e68` and `@ilki/586fcf54-6d07-46f0-a2d9-03abf80e4088`.
- Hypothesis: the reported kill is either an outbound sender/concurrency issue near `AudioChunkSender`, an OS termination not grouped as a TestFlight crash, or a related Apple/PTT/audio-session boundary termination.

## Recommended Next Step

1. Ship a new TestFlight build from current code and verify the call-screen statistics are visible.
2. Reproduce once between `@mau` and `@ilki`; immediately relaunch and pull device diagnostics/crash logs from the connected device.
3. If no `.ips` termination report appears locally and no build `169+` crash appears in Xcode Organizer, add explicit pre-transmit breadcrumbs around `AudioChunkSender` and app lifecycle termination recovery.

## Commands That Matter

```bash
just device-diagnostics-crash-logs "Mauricio’s iPhone" "/tmp/turbo-device-app/mau-after-repro-$(date +%Y%m%d-%H%M%S)"

python3 tools/scripts/reliability_intake.py \
  --base-url https://api.beepbeep.to \
  --surface auto \
  --insecure \
  --device @mau=56febd70-2863-4c6d-af4d-9d67c6bc0e68 \
  --device @ilki=586fcf54-6d07-46f0-a2d9-03abf80e4088 \
  @mau @ilki
```

## Files That Matter

- [`client/ios/Turbo/PCMWebSocketMediaSession.swift`](/Users/mau/Development/bb/client/ios/Turbo/PCMWebSocketMediaSession.swift)
- [`client/ios/Turbo/CallPrototypeView.swift`](/Users/mau/Development/bb/client/ios/Turbo/CallPrototypeView.swift)
- [`client/ios/Turbo/Info.plist`](/Users/mau/Development/bb/client/ios/Turbo/Info.plist)
- [`tools/scripts/device_app.py`](/Users/mau/Development/bb/tools/scripts/device_app.py)
- [`/tmp/turbo-device-app/mau-crash-logs-20260604`](/tmp/turbo-device-app/mau-crash-logs-20260604)
- [`/tmp/turbo-reliability-intake/20260604-092314_mau__ilki`](/tmp/turbo-reliability-intake/20260604-092314_mau__ilki)

## Notes

- Xcode Organizer/App Store Connect absence for build `169` should not block local artifact capture. OS termination reports can be visible on-device even when TestFlight has no grouped app crash.
- Apple documents TestFlight crash reports as available through Xcode Organizer; App Store Connect is still useful for tester feedback and links into Xcode.
