# Swift / iOS Debugging Guide

Status: app-side debugging guide.
Scope: simulator/device interpretation, PushToTalk/audio logs, client-only toggles, Apple boundary loops.
Related docs: [`TOOLING.md`](/Users/mau/Development/bb/TOOLING.md), [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/bb/docs/reliability/STATE_MACHINE_TESTING.md), [`scenarios/README.md`](/Users/mau/Development/bb/README.md), [`PRODUCTION_TELEMETRY.md`](/Users/mau/Development/bb/docs/reliability/PRODUCTION_TELEMETRY.md), [`SELF_HEALING.md`](/Users/mau/Development/bb/docs/reliability/SELF_HEALING.md).

Use this for simulator scenarios, distributed app-side control-plane debugging, device escalation, PushToTalk wake behavior, and audio session/playback issues.

## Default Loop

- run simulator/Xcode agent checks before real-device checks
- use app-owned self-checks before manual tap-through debugging
- rely on persistent diagnostics before screenshots
- use checked-in scenarios for distributed control-plane bugs
- run `just simulator-scenario-merge` before guessing from prose
- run `just reliability-gate-smoke` before treating hosted control-plane changes as stable
- trust exact-device diagnostics only after the wrapper proves nonzero tests executed

Debug builds keep state captures in local diagnostics and coalesce automatic compact latest uploads. Automatic uploads are byte-budgeted, defer while local transmit, remote receive, PTT audio activation, or wake activation is live, and locally downshift to smaller diagnostics before attempting an oversized network upload; use shake/manual reports for immediate capture during or just after a failing physical run. Routine state captures do not go to Cloudflare telemetry by default; set `TURBO_IOS_STATE_CAPTURE_TELEMETRY=1` only for short targeted raw-state timelines.

Physical testing flow:

1. Reproduce the bad audio/control behavior.
2. Stop talking and leave the live audio path idle.
3. Watch the debug diagnostics status on the app surface: queued -> waiting for audio to finish -> uploading -> uploaded/failed.
4. Wait for uploaded before running merged diagnostics. If it fails or never appears, pull device diagnostics with `just device-diagnostics <device>` or `just device-diagnostics-connected`.

Agents should not ask for manual in-app diagnostics upload in the normal loop. If a current debug build has recent activity and `merged_diagnostics.py` cannot find latest backend snapshot, investigate auto-publish/backend diagnostics.

## Merged Diagnostics

Use `TOOLING.md` for exact `just reliability-intake`, `just reliability-intake-shake`, and `merged_diagnostics.py` commands. This guide covers interpretation.

Rules:

- use tester handles, not inferred names
- use JSON output when counting events, comparing transport digests, or scripting
- backend latest snapshots are fetched by default
- full backend transcripts are separate from Cloudflare telemetry metadata
- if local Python cannot verify Cloudflare TLS, use the repo-supported insecure diagnostics fetch in `TOOLING.md`; that changes fetch verification only

Read in layers:

1. Source warnings: telemetry and latest backend snapshots available?
2. Invariant violations: fastest route to owner.
3. Pair timeline: request, join, transmit, background, disconnect, retry.
4. Full transcript anchors: audio/session detail omitted from compact telemetry.

If an invariant describes impossible local/backend state, follow [`SELF_HEALING.md`](/Users/mau/Development/bb/docs/reliability/SELF_HEALING.md): invariant -> owner -> bounded repair -> repair diagnostic -> regression. UI copy alone is not repair.

For audio bugs, telemetry alone is insufficient. Latest transcript should show sender capture (`Captured local audio buffer`, `Converted local audio buffer`, `Enqueued outbound audio chunk`, outbound digest) and receiver playback (`Audio chunk received`, `Playback buffer scheduled`, `Playback node started`). If missing in current debug builds, fix diagnostics/autopublish before drawing audio conclusions.

## Shake Reports

Shake-to-report attempts a compact backend diagnostics upload with a diagnostics-specific timeout, preflights local request size, falls back to smaller diagnostics on oversized payloads or upload failure, and emits `ios.problem_report.shake` when telemetry is enabled. Compact uploads must still preserve structured diagnostics and replayable `engineTrace`. Automatic diagnostics publish compact transcripts after live media is idle.

Inspect in order:

1. Read Discord/telemetry for `incidentId`, `userHandle`, `deviceId`, `uploadedAt`, `diagnosticsLatestURL`, `channelId`, `peerHandle`.
2. Fetch `diagnosticsLatestURL`, or use `just diagnostics-latest <device_id> https://beepbeep.to <user_handle>` if auth headers are needed.
3. Confirm transcript contains `Shake report requested` with matching `incidentId`; inspect `userReport` if present.
4. Run merged diagnostics around the same time; include `peerHandle` when present.

Current report links are latest-snapshot pointers. Use `incidentId` and `uploadedAt` to avoid reading a later upload.

## Audio Packet Policy

Do not emit every audio packet to production telemetry. Packet logs are high-volume and can perturb the real-time path. Cloudflare telemetry should carry lifecycle facts, timings, route failures, and invariants.

Packet-level evidence belongs in backend latest diagnostics:

- sender: `Captured local audio buffer`, `Converted local audio buffer`, `Enqueued outbound audio chunk`, outbound dispatch/delivery digests
- receiver: `Audio chunk received`, `Playback buffer scheduled`, playback start/readiness

Default logs record the first few sender capture/convert/enqueue events and first few relay receive chunks, then emit bounded suppression diagnostics. That proves startup, silence/non-silence, payload size, and digest continuity without huge payloads.

Deep-audio mode, when needed, should be debug/dev or explicit test config only; emit compact per-chunk sequence facts, not raw PCM or full payloads; include digest, sequence/index, chunk count, payload length, frame count, local monotonic timing; summarize captured/enqueued/dispatched/received/scheduled/dropped/suppressed counts and largest inter-arrival/playback gaps; flow into backend latest diagnostics.

Debug transport overrides are `DEBUG`-build behavior. TestFlight and release builds must ignore persisted media-lane override, Direct QUIC relay-only, Direct QUIC auto-upgrade-disabled, media relay force/disable, media relay config, control-command transport, and packet-metadata flags, even when installed over a development build with the same app container. Shipping builds should resolve to production defaults: Direct upgrade allowed when the backend advertises it, Fast Relay enabled but not forced, production relay host/ports, automatic control transport, and packet metadata diagnostics off.

The diagnostics sheet exposes one media lane selector:

| Override | Meaning |
| --- | --- |
| `automatic` | Use Direct QUIC when proven/current, otherwise Fast Relay. |
| `force-direct-quic` | Local sender policy tries Direct QUIC and disables relay rescue for the test cell. |
| `force-fast-relay-quic` | Local sender policy selects Fast Relay QUIC packet media. |
| `force-fast-relay-tls` | Local sender policy selects Fast Relay TCP/TLS ordered fallback. |

Reports include requested override, effective path, active proven lane, and
fallback/rescue reason. Requested override is local policy only; it must not
become backend truth. The sender's chosen current-epoch media lane is carried
by authenticated media/hint metadata. The peer accepts any valid current-epoch
lane even when its own local selector differs, and receive-side relay prejoin may
adapt without changing the peer's stored override. Forced Fast Relay QUIC/TLS
also replaces any cached relay client whose transport does not match the forced
lane before sending live audio.

The diagnostics sheet also exposes one runtime control selector. This selector
is separate from media lane forcing and never authorizes runtime live media.

| Override | Meaning |
| --- | --- |
| `automatic` | Follow runtime config preference and use the first supported authoritative control lane. |
| `http-only` | Force stateless HTTP control for compatibility and bisection. |
| `force-runtime-quic` | Require runtime QUIC control when advertised; otherwise fall back to HTTP and record `runtime-quic-unavailable`. |
| `force-runtime-tls` | Require runtime TLS control when advertised; otherwise fall back to HTTP and record `runtime-tls-unavailable`. |
| `force-runtime-http` | Force runtime HTTP request/response control. |

Forced runtime QUIC/TLS/HTTP policies disable backend WebSocket command
compatibility for control commands. Reports include requested control policy,
effective control lane, persistent/non-persistent classification, and fallback
reason. WebSocket remains a compatibility and scenario fault-injection surface;
it is not a target lane for new authoritative control work.

Current Opus diagnostics:

- `codec=opus` and `frameIndex=<n>` identify Opus v2 frames.
- `codec=legacy-pcm` identifies fallback payloads.
- `packetSizeBytes`, `interArrivalGapNanoseconds`, `bufferDepthFrames`, `targetCushionFrames`, `duplicateDropCount`, `lateDropCount`, `missingFrameCount`, `plcRecoveryCount`, `fecRecoveryCount`, `largestScheduledGapFrames`, and `adaptiveCushionIncreased` describe receiver playout quality without logging packet contents.
- `media.codec_negotiation_mismatch` means an Opus payload arrived where the receiver had no Opus codec available or no negotiated policy should have allowed it.
- `media.playout_excessive_jitter` means receiver packet spacing or scheduled gaps exceeded the current lane tolerance.
- `media.playout_repeated_underrun` means PLC/adaptive cushion growth was needed repeatedly during receive.

`in-band-fec` in capability metadata means the build can produce FEC-capable Opus packets. `in-band-fec` in an individual Opus v2 frame means the active `OpusVoiceEncodingPolicy` enabled encoder FEC for that packet. Receiver playout decodes Opus in scheduled frame order, uses next-packet FEC for the immediately previous missing frame when available, and falls back to native PLC otherwise.

Suspected packet-loss loop:

1. reproduce once on devices
2. save merged diagnostics with `--full-metadata`
3. compare sender enqueue/dispatch digests with receiver `Audio chunk received` digests
4. inspect playback scheduling for gaps, silence, or route/session changes
5. convert receiver packet/playout/scheduler facts into a replayable local corpus:
   `just audio-incident-corpus /tmp/turbo-debug/<run>/merged-diagnostics.json /tmp/turbo-debug/<run>/audio-incident-corpus.json <name>`
6. replay the corpus with `just audio-incident-replay /tmp/turbo-debug/<run>/audio-incident-corpus.json`
7. mutate the same corpus across local transport/playout/scheduler envelopes with `just audio-incident-mutate /tmp/turbo-debug/<run>/audio-incident-corpus.json`
8. if lane semantics explain it, add a `TurboEngine` packet/jitter/backlog scenario first
9. if app execution explains it, add a focused Swift adapter proof for the media boundary
10. keep regression in engine/simulator/local infrastructure when transport/state-machine owned; use devices only for Apple audio-session, PushToTalk, background, route, and actual capture/playback boundaries

Media lane interpretation:

| Diagnostic lane | Expected media primitive | Debug implication |
| --- | --- | --- |
| `direct-quic` | Direct QUIC datagram packet media | Control remains ordered; live audio must arrive through datagrams. Opus is expected when both sides advertise fresh Opus v2 support; otherwise legacy PCM is expected. |
| `media-relay-packet` | Fast Relay QUIC datagram packet media | Loss/reorder/duplicate should be handled by sequence/jitter policy without ordered backlog drops. Opus uses the same peer capability gate as Direct QUIC. |
| `media-relay-tcp` | Fast Relay TCP/TLS ordered stream | Explicit degraded fallback after relay QUIC/datagram failure; inspect ordered backlog/catch-up drops before device retest. Opus may still be used, but the lane is ordered and higher-latency. |

Live packet media sends are best-effort at the transport boundary. Direct QUIC and Fast Relay QUIC datagram audio must not await ordered/reliable send completion such as Network.framework `.contentProcessed`; waiting there can recreate sender-side head-of-line stalls. Keep ordered/reliable completion for control and ordered fallback lanes.

Fast Relay selection has two QUIC steps: ordered control-stream join, then separate QUIC datagram media join. A log pair like `Media relay QUIC datagram unavailable ... datagram handshake timed out` followed by `Media relay TCP ordered fallback connected` means UDP/datagram Fast Relay failed and the app intentionally selected the degraded TCP lane. That is not expected for a Fast Relay packet-media test cell; inspect relay UDP reachability, server datagram ack behavior, or local network UDP blocking.

First-playback ACKs for packet media prove that the receiver played a current-or-newer packet on the expected transport, not necessarily the first packet digest. Accept encrypted ACK sequence `>=` the armed expectation for the same channel/sender/receiver/transport; reject older sequence ACKs. Direct packet media must return after Direct send succeeds; sequential rescue is used when Direct send fails or when Fast Relay is selected as the explicit degraded lane.

## Client-Only UX Shortcut

Shortcut: sender auto-join on Friend acceptance. If Avery sent a Beep and Blake accepts, Avery may auto-join instead of requiring second `Connect`.

Properties:

- client-only
- optional
- reversible for debugging
- does not change backend handshake truth
- underlying request / friend-ready / join states remain source-of-truth

Disable when debugging handshake sequencing:

```lldb
expr PTTViewModel.shared.setSenderAutoJoinOnBeepAcceptanceEnabled(false)
```

Re-enable:

```lldb
expr PTTViewModel.shared.setSenderAutoJoinOnBeepAcceptanceEnabled(true)
```

Persistence key: `turbo.shortcuts.senderAutoJoinOnBeepAcceptance`.

Diagnostics: `selectedConversationAutoJoinEnabled`, `selectedConversationAutoJoinArmed`. Check these before assuming reducer/backend illegally skipped a phase.

## Scenario Loop

For distributed control-plane bugs:

1. run the smallest useful scenario
2. merge diagnostics
3. inspect merged timeline
4. move to physical devices only for Apple/PTT/audio/background behavior

Scenarios should assert machine projections where possible: selected Conversation phase/status, contact-list projections, backend readiness.

For physical-device reports, extract the smallest multi-device event story rather than mirroring every tap:

- which user acted
- what the Friend did
- background/reconnect/restart facts
- expected state
- observed stuck state

Mixed app/backend bugs require inspecting both the client projection and backend route/projection before choosing owner. If backend-owned truth is wrong, frontend guardrails/diagnostics are secondary.

## Device Escalation

Use physical devices only for:

- microphone permission
- real Apple PushToTalk UI
- backgrounding / lock screen
- actual audio playback / capture

Do not continue device experimentation while simulator scenario or probe loop is red.

Use the checked-in devicectl wrappers for device runs:

| Task | Command |
| --- | --- |
| List selectable devices | `just device-list` |
| Build/install/launch one device | `just device-run <device>` |
| Build/install/launch every connected physical iOS device | `just device-run-connected` |
| Launch an already-installed build | `just device-launch <device>` |
| Extract app-container diagnostics | `just device-diagnostics <device>` |
| Extract diagnostics from every connected physical iOS device | `just device-diagnostics-connected` |
| Extract diagnostics plus crash logs | `just device-diagnostics-crash-logs <device>` |
| Gather device sysdiagnose | `just device-sysdiagnose <device>` |
| Run physical-device tests with nonzero-test guardrails | `just device-test <device>` |
| Run physical-device UI tests | `just device-ui-test <device>` |

Device artifacts live under `/tmp/turbo-device-app/`. `device-diagnostics` pulls the app container's `Library/Application Support/Diagnostics` directory and writes a local log tail next to the full copied log. If CoreDevice lists the diagnostics files but closes the directory-transfer socket, the wrapper retries by copying the listed files individually. On physical failure, keep the device UDID or name, command, diagnostics directory, `.xcresult` path, and any merged diagnostics path in the handoff.

## Foreground Audio Smoke

Known-good foreground transmit contract:

1. both sides converge to `ready`
2. hold-to-talk remains disabled while local device is `Preparing audio...`
3. local prewarm enables hold-to-talk
4. first press requests the backend Talk Turn lease before requesting Apple system transmit
5. app prewarms transport/control paths but does not capture or signal live audio until backend lease, Apple `didBeginTransmitting`, and PTT audio activation are all current
6. receiver moves into `receiving` and hears audio on first transmit
7. release plays Apple end beep and both sides converge to `ready`

App-owned invariants:

- local interactive media is prewarmed before hold-to-talk enables
- first transmit rebinds capture to live `PlayAndRecord` only after Apple grants the PTT audio session
- runtime control, Fast Relay, and Direct QUIC share the same backend-lease plus Apple-transmit plus Apple-audio live gate
- no transport lane may send `transmit-start`, capture microphone audio, or project `Talking` from provisional route evidence
- remote `transmit-stop` does not recreate interactive audio while PTT audio session is deactivating
- unexpected system transmit end cleans up or retries without stale transmit

Healthy sender log shape:

- `Backend transmit lease granted`
- `Requesting system transmit handoff`
- `System transmit began`
- `PTT audio session activated`
- `Configured outgoing audio transport`
- `Refreshed capture path for current audio route`
- `Starting audio capture with transport state configured=true`
- `Captured local audio buffer`
- `Converted local audio buffer`
- `Enqueued outbound audio chunk`

Healthy receiver log shape:

- `Signal received ... type=transmit-start`
- `PTT audio session activated`
- `Preparing receive media session after PTT audio activation`
- `Audio chunk received`
- `Playback buffer scheduled`
- `Playback node started`

Interpretation:

- sender reaches backend lease but not `System transmit began` -> suspect Apple PushToTalk begin handoff or channel lifecycle
- sender reaches `System transmit began` but not `PTT audio session activated` -> fail closed; do not expect `transmit-start`
- sender reaches `Starting audio capture...` but not `Captured local audio buffer` -> suspect sender capture engine/tap/route
- receiver reaches `Preparing receive media session...` but not `Audio chunk received` -> suspect sender capture or send path before playback

Stable reference: `@avery -> @blake` foreground transmit around `2026-04-13T16:52Z`. The critical proof is real audio chunks and playback during the same transmit window, not a specific internal branch name.

## Receiver-Ready And Wake-Ready Gates

Foreground receiver-ready:

- each joined device publishes `receiver-ready` only after its receive path is prewarmed
- each device publishes `receiver-not-ready` when readiness is lost
- backend stores readiness per joined device/session and exposes `/readiness.audioReadiness`
- sender enables hold-to-talk only when backend readiness, local warmup, and Friend audio-readiness agree

Thus `Connected` plus enabled hold-to-talk means backend believes the other joined device can hear now.

Wake-ready:

- app uploads ephemeral PushToTalk token after join
- backend exposes token-backed wake capability through `/readiness.wakeReadiness`
- selected conversation enters `wakeReady` only when the Friend is disconnected and `wakeReadiness.peer.kind == wake-capable`
- disconnected Friend without backend wake capability stays waiting

Friend offline is not enough to infer wake is possible. A joined Friend that backgrounds/locks and tears down idle foreground prewarm should become wake-capable, not ordinary `Waiting for <Friend>'s audio...`.

## Background PTT Wake

Foreground signaling uses runtime control. Background receive needs PushToTalk wake:

- direct APNs from Unison is intended long-term path, pending upstream runtime rollout
- interim path uses backend-triggered Cloudflare sender in [`APNS_DELIVERY_PLAN.md`](/Users/mau/Development/bb/docs/client/APNS_DELIVERY_PLAN.md)
- backend chooses wake target through `/ptt-push-target` and `/readiness.wakeReadiness`
- long-term `begin-transmit` builds APNs JWT in Unison and sends `pushtotalk` directly with `Http.request`
- wake results upload to backend diagnostics as `[wake:apns] ...`
- `ptt-apns-worker` and `ptt-apns-bridge` are legacy/debug helpers
- app uploads ephemeral PushToTalk token while joined
- backend uses token for `pushtotalk` push when remote speaker starts
- app `incomingPushResult(...)` returns active remote participant quickly
- PushToTalk activates audio session
- only after activation should app reconnect transport and start background playback

Locked receive rules:

- prefer playback-only media startup under PTT-owned activated audio session
- do not boot capture/input just to play remote audio after wake
- if PTT activation is late, buffer wake audio while locked/backgrounded
- do not fall back to app-managed `AVAudioEngine` until foreground; otherwise CoreAudio can throw `player did not see an IO cycle`
- do not carry idle foreground app-managed interactive media into background unless actively transmitting or already in pending wake

Wake handoff states:

- `signalBuffered`
- `awaitingSystemActivation`
- `fallbackDeferredUntilForeground`
- `appManagedFallback`
- `systemActivated`

Critical distinction: `Incoming PTT push received` without `PTT audio session activated` means APNs delivery worked but Apple PushToTalk activation did not complete. Treat as device/PTT boundary failure.

Expected locked-screen receive order:

1. bridge prints `sent wake push ... status=200`
2. receiver logs `Incoming PTT push received`
3. receiver logs `PTT audio session activated`
4. buffered wake audio drains and playback begins

If receiver only reaches `awaitingSystemActivation`, investigate why Apple never promoted the push into activated PTT audio session.
