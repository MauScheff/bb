# Simulator Scenario Suite

Status: active reference.
Authority: checked-in scenario catalog, scenario DSL, scenario commands, generated inputs, local/hosted lanes, and diagnostics behavior.
Related docs: [`ENGINE.md`](/Users/mau/Development/bb/ENGINE.md) for headless engine scenarios; [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/bb/docs/reliability/STATE_MACHINE_TESTING.md) for report-to-regression rules; [`SIMULATOR_FUZZING.md`](/Users/mau/Development/bb/docs/reliability/SIMULATOR_FUZZING.md) for fuzz mechanics.

Use simulator scenarios for distributed journeys that cross app reducer/coordinator logic, backend Beep/channel truth, simulator PushToTalk shim behavior, and diagnostics publication. Prefer `TurboEngine` package tests or headless engine scenarios for reducer-local call/session/PTT/media/transport invariants.

All `just simulator-scenario*` commands run through `tools/scripts/run_simulator_scenarios.py`, which owns runtime config, serializes the simulator lane, and retries transient XCTest bootstrap failures.

## Proof Layers

| Layer | Use for |
| --- | --- |
| `client/ios/Packages/TurboEngine` | Foundation-only reducer, synthetic media, transport fallback, lifecycle, and virtual ordering proof. |
| `just engine-scenario-local <name>` / `just engine-fuzz-local <seed> <count>` | Same engine against `turbo.serveLocal`. |
| `TurboTests.swift` reducer/domain tests | Idempotence, convergence, duplicate-effect suppression, and local invariants. |
| `shared/scenarios/*.json` | Canonical app/backend/PTT-shim journeys and regressions. |
| Physical devices | Apple PushToTalk UI, microphone permission, backgrounding, lock screen, and real audio. |

## Scenario Catalog

- `presence_online_projection`: both Friends establish a direct channel, heartbeat, refresh summaries, and observe each other online.
- `presence_open_friend_projection`: opening a fresh Friend before a direct channel exists must still surface backend presence instead of selected Conversation offline.
- `foreground-ptt`: both Friends open, converge to `ready`, each transmits once, and foreground system-begin/transmit-startup invariants stay absent.
- `background_wake_refresh_stability`: backgrounding one ready Friend publishes `receiver-not-ready(app-background-media-closed)`; the foreground Friend degrades to `wakeReady` only with aligned Apple PTT session evidence, and refresh/reconcile preserves wake-capable state.
- `background_wake_transmit_does_not_project_receiver`: local wake-target regression; foreground transmit toward a background/wake-capable receiver must not project receiver `receiving` without joined/session evidence.
- `wake_token_revocation_clears_active_transmit`: local wake-target regression; token revocation must clear backend active transmit for a wake-token-only target.
- `active_transmit_sender_disconnect_clears_transmit`: local membership-loss regression; sender disconnect during transmit must clear backend/client live transmit.
- `friend_disconnect_before_second_join`: recipient accepts and joins first, then disconnects before sender finishes second join; both sides converge idle.
- `beep_accept_ready`: baseline Beep, accept, ready, transmit, stop, disconnect.
- `beep_accept_ready_disconnect_initiator`: ready Conversation torn down by initiator without transmit.
- `beep_accept_ready_disconnect_receiver`: ready Conversation torn down by receiver without transmit.
- `beep_accept_ready_refresh_stability`: summary/Beep/channel refresh plus reconciliation must preserve a ready Conversation.
- `beep_accept_ready_receiver_ready_gate`: delayed first `receiver-ready` on both sides must keep handshake in `waitingForPeer` until backend/audio readiness converges.
- `receiver_readiness_transitional_media_regression`: local fuzz regression from seed 20260556; delayed readiness observation and transmit-end convergence must not publish duplicate receiver readiness or publish `receiver-ready` from transitional media evidence.
- `receiver_readiness_pending_leave_regression`: local fuzz regression from seed 20260573; dropped transmit-start delivery plus disconnect convergence must not publish duplicate receiver readiness or publish `receiver-ready` while a leave is in flight.
- `beep_accept_ready_friend_transmit`: recipient transmits from ready state, returns to `ready`, and disconnects cleanly.
- `selected_contact_direct_quic_prewarm`: selecting/opening contact must not join or transmit; Direct QUIC prewarm may retry after metadata refresh and must skip safely when identity/routing is insufficient.
- `duplicate_connect_beep_deduplicates`: duplicate sender connect intents converge to one outgoing Beep before `ready`.
- `disconnect_refresh_convergence`: after ready-session disconnect, refresh/reconcile converges both sides idle without reviving stale joined state.
- `delayed_accept_refresh_race`: stale sender refresh/reconcile during delayed acceptance still converges through `friendReady` to `ready`.
- `dropped_transmit_start_poll_recovery`: local transport-fault regression; dropped `transmit-start` websocket signal recovers through explicit refreshes.
- `duplicate_transmit_stop_delivery_recovers`: local transport-fault regression; duplicated `transmit-stop` still converges back to `ready` without stale receiving/talking invariants.
- `reordered_transmit_signals_refresh_recovery`: local transport-fault regression; reordered `transmit-start`/`transmit-stop` recovers through refresh/reconcile without stale receiving/talking invariants.
- `stale_transmit_stop_completion_emits_invariant`: local expected-invariant regression; stale stop completion against newer transmit emits `transmit.stale_end_overrides_newer_epoch`; use non-strict merge.
- `lease_expiry_renewal_delay_recovers`: local lease-fault regression; delayed `renew-transmit` past lease expiry converges both Friends to `ready` without `transmit.live_projection_after_lease_expiry`.
- `backend_reconnect_ready_session_recovery`: full backend/control-plane reconnect during `ready` must refresh and recover the same ready Conversation under the backend `readiness`/`audioReadiness` contract.
- `restart_ready_session_recovery`: app restart after ready Conversation must restore local ready Conversation and backend `audioReadiness=ready`.
- `restart_ready_session_recovery_with_offline_repair`: local fuzz regression from seed 124; restart, delayed receiver signaling, and background/foreground disconnect must avoid `presence.offline_retained_connected_session`.
- `disconnect_clears_stale_friend_presence_during_state_refresh`: local fuzz regression from seed 123; receiver disconnect racing channel-state refreshes must repair stale presence and keep strict diagnostics clean.
- `restart_partial_join_recovery`: sender restart during partial join must restore sender `friendReady`, preserve recipient `waitingForPeer`, and allow second join to reach `ready`.
- `fast_relay_idle_network_migration`: local transport-policy hardening; idle Wi-Fi to cellular migration keeps selected path `fast-relay`.
- `fast_relay_active_transmit_network_migration`: active Fast Relay transmit survives Wi-Fi to cellular migration.
- `direct_quic_active_transmit_network_migration`: Direct QUIC path loss during transmit surfaces explicit relay fallback instead of stale Direct UI or `direct-quic.active_path_surfaced_as_relay`.
- `fast_relay_lock_unlock_recovery`: receiver lock degrades sender to wake-ready; unlock plus refresh restores readiness while Fast Relay remains surfaced.
- `direct_quic_lock_unlock_recovery`: lock/unlock must not corrupt active Direct QUIC surfaced path or emit active-path-as-relay invariant.
- `beep_cancel_before_accept`: caller withdraws before the Friend accepts.
- `beep_decline`: recipient declines incoming Beep.
- `simultaneous_beep_conflict`: simultaneous Beeps converge to one ready Conversation.

`backend_reconnect_ready_session_recovery` proves that runtime-control reconnect
and explicit refresh reassert ready-session truth deterministically.

For transmit scenarios, `ready` means `phase=ready` and `canTransmitNow=true`. Simulator scenarios prove hold-to-talk enablement; physical-device smoke still proves first real transmit produced audible audio through Apple/PTT/media boundaries.

## Rules

- Add a checked-in scenario when a distributed regression is reproducible in simulator.
- Add lower-level property/reducer tests for the invariant that prevents recurrence.
- Prefer typed assertions over selected Conversation phase alone: selected Conversation projection, contact list, backend readiness, backend audio readiness, and effect-safe convergence after retry/delay.
- Update this README when adding or renaming a checked-in scenario.
- For expected-invariant scenarios, use focused run plus normal merge; use strict merge only after converting the scenario to absence/regression proof.

## Commands

| Command | Meaning |
| --- | --- |
| `just simulator-scenario <scenario>` | Runs `TurboTests/SimulatorScenarioTests`; `.scenario-runtime-config.json` selects the checked-in JSON scenario. |
| `just simulator-scenario-suite` | Runs all checked-in `shared/scenarios/*.json` files in sorted order. |
| `just simulator-scenario-merge` | Merges latest exact-device diagnostics for `sim-scenario-avery` and `sim-scenario-blake`. |
| `just simulator-scenario-merge-strict` | Same merge, nonzero on invariant violations. |

## DSL

The DSL supports user intents plus control-plane forcing actions: refreshes,
waits, presence heartbeats, direct-channel establishment, backend reconnect, and
`restartApp`.

| Field/action | Contract |
| --- | --- |
| `delayMilliseconds` | Deliver the action later within the step; use for races and explicit actor reordering. |
| `repeatCount` | Deliver the same action more than once. |
| `repeatIntervalMilliseconds` | Space duplicate deliveries. |
| `drop` | Omit an action without removing it from scenario JSON. |
| `resetTransportFaults` | Clear all configured HTTP and websocket faults for the actor. |
| `setHTTPDelay` | Requires `route`, `milliseconds`, optional `count`; delays typed route requests. |
| `setWebSocketSignalDelay` | Requires `signalKind`, `milliseconds`, optional `count`; delays inbound websocket delivery. |
| `dropNextWebSocketSignals` | Requires `signalKind`, optional `count`. |
| `duplicateNextWebSocketSignals` | Requires `signalKind`, optional `count`. |
| `reorderNextWebSocketSignals` | Requires `count >= 2`, optional `signalKind`; buffers then flushes in reverse order. |
| `captureDiagnostics` | Records a diagnostics capture and reruns derived invariant checks, including time-sensitive checks. |
| `setNetworkInterface` | Requires `networkInterface`, optional `reason`; values: `wifi`, `cellular`, `wired`, `other`, `unavailable`, `unknown`. |
| `setMediaTransportPath` | Requires `pathState`; values: `relay`, `fast-relay`, `promoting`, `direct`, `recovering`. |
| `activateDirectQuicPath` | Requires a selected contact; creates active selected-contact Direct QUIC attempt and surfaces `direct`. |
| `loseDirectQuicPath` | Optional `reason`; requires selected contact with active Direct QUIC attempt. |
| `lockApp` / `unlockApp` | Lock/unlock aliases for background/foreground coverage. |
| `injectStaleTransmitStopCompletion` | Test-only reducer injection; constructs newer active transmit, delivers older stop, and requires `transmit.stale_end_overrides_newer_epoch`. |
| `revokeEphemeralToken` | Test/local backend action; requires selected backend channel, revokes current device ephemeral PTT token, then refreshes selected channel state. |

Transport-fault actions are typed and bounded. Unknown routes or signal kinds fail fast instead of accepting arbitrary strings.

Typed HTTP routes: `contact-summaries`, `incoming-beeps`, `outgoing-beeps`, `channel-state`, `channel-readiness`, `renew-transmit`.

Typed websocket signal kinds use backend signal names already exercised by app/tests, such as `transmit-start` and `transmit-stop`.

`disconnectWebSocket` suspends websocket reconnection until explicit `reconnectWebSocket`; this keeps transport-fault scenarios deterministic.

## Expectations

Invariant checks are measured from the start of the current step, so one scenario can prove both expected emission and later non-emission.

| Field | Contract |
| --- | --- |
| `noInvariantViolations` | When `true`, no new invariant violations may be emitted by that actor during the step. |
| `expectInvariant` | Registered invariant IDs that must be emitted during the step. |
| `eventuallyNoInvariant` | Registered invariant IDs that must not be emitted during the step. |
| `allowInvariantDuringStep` | Registered invariant IDs exempted from `noInvariantViolations`; only for intentional bounded violations. |

## Generated Inputs

The XCTest runner defaults to checked-in `shared/scenarios/*.json`. Runtime config also accepts `scenarioFile` for one external JSON file and `scenarioDirectory` for every `*.json` in a temporary directory. `tools/scripts/run_simulator_scenarios.py` exposes these as `--scenario-file` and `--scenario-directory`, used by fuzz replay from `/tmp/turbo-scenario-fuzz` without copying artifacts into the repo.

## Fuzz Lane

The generator biases post-transmit toward active-transmitter membership loss (`beginTransmit` then sender `disconnect`) and wake-token addressability loss (`backgroundApp`, `beginTransmit`, `revokeEphemeralToken`).

Use local websocket backend for volume:

1. `just serve-local`
2. `just simulator-fuzz-local 123 3`
3. `just reliability-fuzz-local-overnight 12345 500`
4. On failure, use printed replay/shrink commands.

Use `just simulator-fuzz-local-overnight 12345 500` only when you explicitly want the simulator lane without the preceding headless engine fuzz pass.

The runner requires 4 GiB free at the artifact root before each batch. Each seed directory stores `scenario.json`, `metadata.json`, `xcode-output.txt`, merged diagnostics text/JSON/strict text, extracted/replayed engine trace artifacts, `result.json`, and `minimized.json` when shrinking preserves failure.

Promotion: inspect minimized scenario and diagnostics, fix the authoritative subsystem, then copy a stable regression into `shared/scenarios/` with a clear name and README entry. Full workflow: [`SIMULATOR_FUZZING.md`](/Users/mau/Development/bb/docs/reliability/SIMULATOR_FUZZING.md).

## Production Replay Conversion

Use production replay conversion when `tools/scripts/merged_diagnostics.py --json` captures a real failure that should become a local proof artifact:

```bash
just production-replay /path/to/merged-diagnostics.json /tmp/turbo-production-replay
```

The converter writes `production-replay.json`, `scenario-draft.json`, `metadata.json`, and `reproduce.sh`. Drafts use safe replay handles and redacted source identities. Treat drafts as approximations: run `reproduce.sh`, inspect strict merged diagnostics, then minimize and promote only stable regressions.

## Synthetic Conversation Probes

Use the synthetic two-device probe for backend/control-plane canaries without simulator app instances:

```bash
just synthetic-conversation-probe https://beepbeep.to @quinn @sasha 1 /tmp/turbo-synthetic-conversation-probe --insecure
```

The wrapper runs `tools/scripts/route_probe.py --json`, requires websocket registration, receiver readiness, begin transmit, push target selection, and end transmit, then writes per-iteration reports plus `synthetic-conversation-probe.json`. Probes prove route semantics quickly; scenarios prove app projection and diagnostics.

## SLO Dashboards

For hosted verification, prefer:

```bash
just postdeploy-check
```

This runs the synthetic conversation probe, generates the SLO dashboard, and writes timestamped `postdeploy-check.json`. Use `just beepbeep-backend-production-gate` for the active production backend gate.

Turn a synthetic probe summary into a static product-facing SLO dashboard:

```bash
just slo-dashboard /tmp/turbo-synthetic-conversation-probe/synthetic-conversation-probe.json /tmp/turbo-slo-dashboard
```

The dashboard enforces conversation success rate, full-probe p95 latency, and critical-check p95 latency for receiver readiness, begin transmit, push target selection, and end transmit. It writes `slo-dashboard.json`, `slo-dashboard.md`, and `reproduce.sh`, and exits nonzero on breach. Use `tools/scripts/slo_dashboard.py` directly to include backend stability probe output or merged diagnostics invariant counts.

## Local Backend Loop

Use local control plane when hosted scenario runs are noisy.

| Backend | Commands | Use for |
| --- | --- | --- |
| Self-hosted Rust runtime at `http://127.0.0.1:8091/s/turbo` | `just self-hosted-serve`; `just simulator-scenario-suite-self-hosted`; `just self-hosted-http-probe`; `just self-hosted-websocket-probe` | Full ready/transmit flows, websocket semantics, route composition, and control-plane convergence. |

`just route-probe-local` checks nested `beepThreadProjection`, `membership`, `summaryStatus`, `conversationStatus`, `readiness`, `audioReadiness`, and `wakeReadiness` through request -> receiver-ready -> token upload -> ready -> transmit -> ready. Because the app consumes `/readiness` directly, readiness regressions should be asserted against that route rather than inferred only from `/channel-state`.

`just simulator-scenario-suite-local` assumes `just serve-local` is already running; unavailable backend fails with connection-refused infrastructure errors. Canonical suite lanes:

- hosted: `just simulator-scenario-suite`
- hosted smoke subset: `just simulator-scenario-suite-hosted-smoke`
- local websocket backend: `just simulator-scenario-suite-local`

Scenarios with `"requiresLocalBackend": true` only run through the local websocket lane and are skipped from hosted suite runs unless explicitly targeted with a local base URL. Keep transport-fault and websocket-connectivity recovery scenarios local unless deployed infrastructure proves the same invariant reliably.

## Scenario Diagnostics

Scenario runs publish explicit diagnostics artifacts after completion. `just simulator-scenario-merge`, `just simulator-scenario-merge-strict`, and exact-device verification read those artifacts.

Normal debug builds may auto-publish diagnostics, but simulator scenario view models disable automatic publishing so the scenario-tagged artifact remains authoritative. The merged analyzer reads structured diagnostics first, falls back to legacy `INVARIANT VIOLATIONS` transcript sections, derives pair-level rules, and supports `--json` plus `--fail-on-violations`.
