# Reliability Sprint Plan

Status: active Track 6 sprint. Tracks 1-5 are complete. This plan owns physical validation of Apple/PTT/audio/background boundaries and conversion of shared-logic failures into local proof artifacts.

## Baseline

Tracks 1-3 closed in `handoffs/2026-05-14-1520.md`; Tracks 4-5 closed in `handoffs/2026-05-14-1732.md`.

Known completed proofs:

- `just engine-test`
- `just engine-scenario-local foreground_transmit_receive`
- `just engine-fuzz-local 12345 500`
- `just swift-test-suite`
- `python3 scripts/check_invariant_registry.py`
- `python3 -m unittest scripts.test_merged_diagnostics`
- `just reliability-gate-regressions`
- `just swift-test-target absentBackendMembershipClearsStalePendingLocalJoinWithoutForceQuit`
- `just swift-test-target absentBackendMembershipRecoveryIsIdempotentAfterStalePendingJoinClears`
- `just swift-test-target absentBackendMembershipDoesNotClearPendingLocalJoinWhileBackendJoinIsSettling`
- `just swift-test-target selectedSyncPreservesPendingJoinWithUnresolvedLocalJoinAttemptAfterSettlingTTL`

Do not reopen Tracks 1-5 unless physical-device evidence contradicts their invariants.

## Roles

| Role | Responsibilities |
| --- | --- |
| Device operator | Run the specified cell, report run ID/cell/transport/app states/path labels/audio result/shake IDs, shake both devices on failure, stop after serious failure unless asked for targeted retest. |
| Agent reliability owner | Run intake/diagnostics/probes/replay/gates, classify owner before editing, convert shared failures into durable proof, fix owner, request minimal retest only after automated proof is green. |

## Non-Goals

- Do not use physical testing as a substitute for automated proof of shared app/backend behavior.
- Do not continue the whole matrix after a serious failure. Stop, capture evidence, classify, prove, fix, and retest the smallest failed cell.
- Do not ask for manual in-app diagnostics upload during the normal loop. Current debug builds should auto-publish latest full diagnostics after high-signal activity; missing latest snapshots are themselves a diagnostics/autopublish issue.
- Do not treat screenshots as authoritative when merged diagnostics can answer the behavioral question.
- Do not count a Direct QUIC cell as passing if it silently used relayed audio unless the test explicitly expected fallback.
- Do not classify a device-found failure as Apple/PTT/audio-only until engine replay/modeling and Swift adapter proof are inapplicable or already green.

## Prerequisites

Automated baseline before starting/resuming physical matrix:

```bash
just engine-test
just reliability-gate-regressions
```

If local backend semantics changed:

```bash
just serve-local
just engine-scenario-local foreground_transmit_receive
just engine-fuzz-local 12345 500
```

Do not ask the physical operator to retest shared session/media/transport behavior until the relevant automated lane is green.

Device setup:

- two iPhones: `<A_HANDLE>`, `<B_HANDLE>`
- backend: `https://beepbeep.to` unless changed by agent
- build: latest debug/TestFlight/production-like build under test
- permissions: microphone, notifications, Local Network
- first pass: Low Power Mode off, Focus/Do Not Disturb off
- Direct QUIC cells: both devices on same Wi-Fi unless testing cellular/NAT
- app setup: signed in, contacts opened, `Profile -> Diagnostics` visible
- record diagnostics fields when visible: app/build, `Local device`, `WebSocket`, `Path state`, `Relay-only override`, `Auto-upgrade`, `Media relay enabled`, `Media relay forced`, `Backend advertised`, `Effective upgrade`
- unknown `Local device`: first intake by handle only; use summary device IDs for exact reads later

Recommended operator report template:

```text
T6 run:
- run ID:
- A handle / device:
- B handle / device:
- build:
- backend:
- network:
- cell:
- transport mode:
- starting app states:
- visible path labels:
- A->B heard first press?:
- B->A heard first press?:
- final states:
- shake incident IDs, if any:
- notes:
```

## Transport Modes

Set transport on both phones from `Profile -> Diagnostics -> Direct QUIC`.

| Mode | Purpose | Toggles | Pass evidence |
| --- | --- | --- | --- |
| T1 WebSocket-only fallback relay | baseline hosted websocket relay path | relay-only on; auto-upgrade off; media relay off; force media relay off | path `Relayed`; `Effective upgrade: no`; no active Direct QUIC; foreground audio works both directions |
| T2 Fast Relay | low-latency media relay without Direct QUIC | relay-only off; auto-upgrade off; media relay on; force media relay on; relay `relay.beepbeep.to` UDP/TCP 443 | media relay enabled/forced/configured; path `Fast Relay`; Direct QUIC inactive |
| T3 Direct QUIC | device-to-device promotion and first-talk behavior | relay-only off; auto-upgrade on; media relay on; force media relay off; Local Network allowed | backend advertised/effective upgrade yes; production identity ready; peer device known; path `Direct` |

T2 old ports `9443`/`9444` are debug fallback only. T3 `Promoting`, `Recovering`, or `Relayed` is not a pass; use `Force probe` once only if asked. Later retry-only audio success is a T3 failure.

### Network-Migration Hardening Cells

Run only after foreground T1-T3 baseline passes on the same build.

- Fast Relay idle prewarm: start on Wi-Fi, select/open the peer until `Fast Relay`, switch the sender to cellular, then first-press audio must still be heard.
- Fast Relay active transmit: start on Wi-Fi, begin transmit, switch the sender to cellular during the transmit window, and audio must continue or recover without ending the session.
- Direct QUIC active transmit: start on same Wi-Fi until `Direct`, begin transmit, switch one side to cellular, and diagnostics must show either Direct recovery/reprobe or an explicit fallback path without stale `Direct` UI.
- Lock/unlock while Fast Relay or Direct QUIC is active: lock the receiver during a ready session, unlock, and confirm the next first press is heard on the expected path.

If a migration cell fails, stop the matrix, run reliability intake, and classify whether the owner is app policy, relay/Direct QUIC transport, backend control-plane truth, or Apple/PTT/audio boundary.

## App-State Matrix

Run the cells in this order. Stop on the first serious failure.

| Cell | App states | Sender action | Required coverage |
| --- | --- | --- | --- |
| S1 | A foreground, B foreground | A sends, then B sends | Baseline ready, first press audio, release convergence |
| S2 | A foreground, B backgrounded or locked | A sends to B | Wake-capable receiver, incoming PTT push, activation, playback |
| S3 | B foreground, A backgrounded or locked | B sends to A | Same as S2 with device roles swapped |
| S4 | A backgrounded or locked, B backgrounded or locked | Start from system PTT UI if available | Lock-screen/background sender plus locked receiver |

Run transport modes in this sequence:

1. T1 x S1
2. T2 x S1
3. T3 x S1
4. T1 x S2 and S3
5. T2 x S2 and S3
6. T3 x S2 and S3
7. S4 for each transport mode that passed S1-S3

S4 is allowed to be `blocked` instead of `failed` if the current build or iOS surface exposes no system sender affordance while the sender app is backgrounded or locked. Capture that as a product/platform limitation with diagnostics; do not invent taps to force it.

## Per-Cell Operator Script

Use a fresh run ID:

```text
T6-YYYYMMDD-HHMM-<transport>-<cell>
```

Per cell:

1. Set the transport toggles on both phones.
2. Fully foreground both apps.
3. Open/select the peer on both phones.
4. Wait until the intended state appears:
   - foreground receiver: `Connected` / `ready`; hold-to-talk enabled only after `Preparing audio...` clears
   - background receiver: sender wake-capable or transmit-capable; receiver backgrounded/locked
   - Direct QUIC: path `Direct`, or clearly active Direct QUIC attempt for first-talk promotion
5. Speak a unique phrase for each direction: `A to B <run ID>` and `B to A <run ID>`.
6. Press and hold for 3 seconds. Release. Wait 5 seconds.
7. Record whether the receiver heard the first press, whether the receiver UI showed `receiving`, whether the sender showed `transmitting`, and whether both sides returned to `ready`/`Connected` or the expected wake-ready state.
8. If anything violates expectations, stop and follow the failure capture script.

## Expected Healthy Behavior

| Surface | Expected |
| --- | --- |
| Foreground | both ready; hold-to-talk disabled during `Preparing audio...`; first press starts Apple beep, sender `transmitting`, receiver `receiving` with audio; release returns both to ready; no current invariant violations |
| Background/locked receiver | sender uses backend wake readiness; receiver logs incoming PTT push and `PTT audio session activated`; buffered wake audio drains during same transmit window |
| Activation failure | `Incoming PTT push received` without `PTT audio session activated` is Apple/PTT activation boundary until proven otherwise |
| Transport | T1 `Relayed`; T2 `Fast Relay`; T3 `Direct`; no masked fallback counted as pass |
| Merged diagnostics | sender transmit/audio-buffer logs; receiver signal/PTT/audio/playback logs; source warnings ideally zero; current violations zero |

## Failure Capture Script

On the first serious failure:

1. Stop the matrix.
2. Shake both phones.
3. In the shake text field, enter:

```text
T6 <run ID> <cell> <transport> <short observed failure>
```

4. Wait 20-30 seconds for auto-publish.
5. Send the agent: run ID, cell ID, transport, handles, path labels, audio result, final visible states, shake IDs, lock/background state.

The agent then runs intake. Use exact device IDs when known:

```bash
python3 scripts/reliability_intake.py \
  --base-url https://beepbeep.to \
  --surface debug \
  --backend-timeout 8 \
  --telemetry-hours 2 \
  --telemetry-limit 500 \
  --output-dir /tmp/turbo-track6/<run-id> \
  --device <A_HANDLE>=<A_DEVICE_ID> \
  --device <B_HANDLE>=<B_DEVICE_ID> \
  --insecure
```

If exact device IDs are not known yet:

```bash
just reliability-intake <A_HANDLE> <B_HANDLE>
```

For a shake-specific report:

```bash
just reliability-intake-shake <REPORTING_HANDLE> <INCIDENT_ID> <PEER_HANDLE>
```

The agent should inspect:

```bash
jq '.telemetryEventCount, .sourceWarnings, .currentViolations, .historicalViolations' /tmp/turbo-track6/<run-id>/merged-diagnostics.json
rg -n "VIOLATION|invariant|error|failed|timeout|transmit|receive|wake|audio|route|Direct QUIC|Media relay|PTT audio session|Incoming PTT push|Captured local audio buffer|Audio chunk received|Playback buffer scheduled" /tmp/turbo-track6/<run-id>/merged-diagnostics.txt
```

## Agent Debug Loop After Failure

1. Confirm source quality: backend latest snapshots, telemetry count, source warnings, shake marker, exact devices.
2. Classify boundary: `crosses engine boundary`, `app adapter/effect executor`, `distributed integration`, or `Apple/PTT/audio boundary`.
3. Classify owner: app/client projection, backend/control-plane truth, app/backend contract, relay/Direct QUIC transport, Apple/PTT/audio boundary, diagnostics/autopublish.
4. Name or register the violated invariant.
5. Build a contradiction ledger; do not stop at the first root cause if diagnostics show additional broken preconditions, postconditions, liveness guarantees, or observability gaps.
6. Map each ledger item to existing `invariantId`, new registry entry plus detector/proof, or explicit deferral with missing evidence.
7. Choose the narrowest proof lane: engine trace replay first for engine-boundary failures from current diagnostics, then engine scenario/fuzz if no trace exists; Swift adapter proof for effect-executor failures; backend proof/probe for backend truth; simulator scenario or strict merged diagnostics for distributed integration; physical retest only for unreplayable Apple/PTT/audio surfaces.
8. Make proof fail when feasible, fix owner, run focused proof plus smallest broad gate, then retest only the failed cell first.

## Optional Hosted Preflight

Use these when the hosted surface itself is suspect before blaming devices:

```bash
just backend-stability-probe https://beepbeep.to <A_HANDLE> 10 8
just websocket-stability-probe https://beepbeep.to <A_HANDLE> <B_HANDLE> 90 20 0
just hosted-backend-client-probe
just direct-quic-provisioning-probe
just turn-policy-probe
```

Run `just turn-policy-probe "--require-enabled"` only when the Direct QUIC test explicitly requires TURN to be enabled.

## Closeout

Track 6 closes when all unblocked cells pass or have tracked issues with artifacts; every shared-logic failure has local proof; every Apple/PTT/audio-only failure has exact physical evidence and unreplayable-boundary explanation; final strict merged diagnostics has no current violations; final handoff lists run IDs, artifacts, changed files, proof commands, risks, skipped/blocked cells.

Final gate selection:

- App-only fix: focused Swift proof plus `just reliability-gate-regressions`.
- Distributed app/backend fix: focused proof, scenario when journey evidence matters, strict merged diagnostics, then `just reliability-gate-smoke`.
- Backend/control-plane fix: backend proof/probe, invariant registry check if touched, then `just reliability-gate-regressions` or stronger.
- Diagnostics/merged analyzer fix: `python3 scripts/test_merged_diagnostics.py`, replay fixture smoke, and `just reliability-gate-regressions`.
- Device-only Apple/PTT/audio fix: local shared-logic proof first, then targeted physical retest of the failed cell.
