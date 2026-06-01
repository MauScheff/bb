# Tooling Guide

Operational command reference. Use `WORKFLOW.md` for proof strategy and this file for exact tools.

Active backend tooling is BeepBeep-first: Rust runtime and infrastructure live under [`beepbeep/backend`](/Users/mau/Development/Turbo/beepbeep/backend), active Unison kernel definitions live under `beepbeep.*`, and the canonical deployed base URL is `https://staging.beepbeep.to`.

## Selection Rules

- Use the thinnest tool that proves the claim.
- Prefer `just` recipes for repeated workflows.
- Use `TurboEngine` package tests/scenarios for engine-owned Conversation, Connection, media, and low-level transport rules.
- Escalate to simulator scenarios only for iOS app target, backend route/projection behavior, scenario DSL actions, or merged diagnostics.
- Use physical devices only for real Apple PushToTalk, permissions, backgrounding, audio-session activation, and audible media.
- Use Unison MCP/UCM for backend kernel code; repo `.u` files are scratch or archived reference, not source of truth.
- Use `just beepbeep-backend-gate` before trusting changes to the Rust runtime or Unison kernel.

Use [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md) for the higher-level thinking model and [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md) for scenario mechanics.

## Tool Map

| Area | Tool | Source/artifacts |
| --- | --- | --- |
| Engine core | `just engine-test`, `just engine-scenario`, `just engine-scenario-local`, `just engine-fuzz-local` | `Packages/TurboEngine`, `/tmp/turbo-engine-fuzz/` |
| Swift app | `just swift-test-target`, `just swift-test-suite`, Xcode wrappers | `Turbo/`, `TurboTests/`, `.xcresult` |
| Physical device app loop | `just device-list`, `just device-run`, `just device-test`, `just device-ui-test` | connected iOS devices, `/tmp/turbo-device-app/`, `/tmp/turbo-device-derived-data/` |
| BeepBeep backend | `just beepbeep-backend-gate`, `just beepbeep-backend-staging-gate`, `just beepbeep-backend-cutover-readiness` | `beepbeep/backend`, Unison namespace `beepbeep.*`, `/tmp/beepbeep-backend-reliability-gate.json` |
| Legacy Cloud backend | Unison MCP/UCM, `turbo.serveLocal`, `turbo.deploy` | Unison codebase `turbo/main`; reference/maintenance only |
| Simulator scenarios/fuzz | `just simulator-scenario*`, `just simulator-fuzz-local*`, `just reliability-fuzz-local-overnight` | `scenarios/`, `/tmp/turbo-scenario-fuzz/`, merged diagnostics and engine trace artifacts |
| Diagnostics | `just reliability-intake*`, `scripts/merged_diagnostics.py` | `/tmp/turbo-reliability-intake/`, `/tmp/turbo-debug/` |
| Probes | route/backend/websocket/client probes | JSON artifacts printed by commands |
| APNs/PTT wake helpers | `ptt-push-target`, `ptt-apns-worker`, `ptt-apns-bridge` | debug/interim wake paths |

## Common entrypoints

For deploys, the distinction is:

- for the active BeepBeep backend reliability loop, use `just beepbeep-backend-gate`; it composes kernel fuzzing, corpus export, Rust runtime fuzzing/integration, HTTP/websocket probes, shadow comparison, and local production-scenario fuzzing
- for deployed staging verification of the active backend, use `just beepbeep-backend-staging-gate`; it targets `https://staging.beepbeep.to`
- for a machine-readable release decision, use `just beepbeep-backend-cutover-readiness`
- for the normal day-to-day verified deploy path, use
  `just deploy-staging-verified`
- for the strict production release path, use `just deploy-production`; it runs
  `just production-preflight`, then deploys, then runs the hosted synthetic
  conversation canary and SLO dashboard
- if a deploy already happened and you only need live verification, use
  `just postdeploy-check`
- if no interactive `ucm` process is already occupying the local codebase and
  you deliberately want only the raw backend deploy primitive, use `just deploy`
- if you are already working inside a live `ucm` session, `just deploy` can block on that codebase lock; in that case keep using the existing codebase session and run `turbo.deploy` there via MCP/UCM

`just deploy` first runs `just backend-schema-drift-test`, which executes `turbo.schemaDrift.check`. This is the lightweight guard against accidentally changing the shape of values stored in Unison Cloud tables without an explicit migration/reset decision. If the guard fails, do not bypass it with an environment rotation as a normal workflow; follow [`MIGRATIONS.md`](/Users/mau/Development/Turbo/MIGRATIONS.md), then either revert the persisted type change, write and prove the migration/repair path, or deliberately approve the new baseline in `turbo.schemaDrift.expectedHashes` in the same change.

If hosted simulator scenarios start timing out after a deploy, do not assume schema drift immediately. First confirm the raw hosted surface with `just route-probe` or `just backend-stability-probe`. A passing raw hosted probe plus flaky simulator-hosted scenarios usually points to transport/test-lane instability, not a reason to rotate the environment. Environment rotation stays a manual operator recovery for disposable environments, not an automatic production step.

In either case, if you changed backend behavior in the local Unison codebase, that change is not live on `https://staging.beepbeep.to` until `turbo.deploy` has actually run.

`just deploy-staging-verified` runs `just swift-test-suite`, deploys, then runs hosted verification.

`just production-preflight` is the expensive local proof gate before production:

- `just swift-test-suite`
- `just reliability-gate-regressions`
- `just reliability-gate-full`

`just deploy-production` runs preflight, deploys, then verifies hosted SLOs. If verification fails after deploy, inspect the printed `postdeploy-check.json`, `synthetic-conversation-probe.json`, and `slo-dashboard.json` artifacts before deciding to roll forward, roll back, or convert the failure into a regression.

`just deploy-verified` remains as a compatibility alias for
`just deploy-staging-verified`.

For APNs credentials, keep the `.p8` file outside the repo and expose either `TURBO_APNS_PRIVATE_KEY_PATH` or `TURBO_APNS_PRIVATE_KEY` in the local deploy environment. `turbo.deploy` resolves the path locally when present and stores the PEM text in cloud config as `TURBO_APNS_PRIVATE_KEY`, so deployed backend code should never depend on filesystem access.

For current real-device background/lock-screen wake testing, do not assume hosted Unison Cloud can send APNs directly yet. Direct APNs-from-Unison is the intended end state, but it is currently waiting on the upstream runtime rollout. Use the interim Cloudflare sender plan in [APNS_DELIVERY_PLAN.md](/Users/mau/Development/Turbo/APNS_DELIVERY_PLAN.md) for the production-shaped path.
Set `TURBO_APNS_TEAM_ID`, `TURBO_APNS_KEY_ID`, and either `TURBO_APNS_PRIVATE_KEY_PATH` or `TURBO_APNS_PRIVATE_KEY` in the deploy environment before `turbo.deploy`. Optional `TURBO_APNS_BUNDLE_ID` and `TURBO_APNS_USE_SANDBOX` are also copied into cloud config when present.
For the current Cloudflare sender path, `TURBO_APNS_WORKER_SECRET` and `TURBO_APNS_WORKER_BASE_URL` must also be present in the deploy environment before `turbo.deploy`.
`ptt-apns-bridge` and `ptt-apns-worker` still exist as legacy/debug helpers. They are not the preferred interim production path.
Wake-send attempts should still be uploaded to the backend dev diagnostics surface so `merged_diagnostics.py` includes them in the merged timeline as `[wake:apns] ...` events.

## Deploying new backend env vars

When introducing a new backend environment variable, treat it as a three-part change:

1. Add the variable to the local deploy environment.
2. Add the key to `turbo.config.seedKeys` so `turbo.deploy` copies it into the named cloud environment.
3. If the value must be transformed before storage, extend `turbo.deploy.internal.seedCurrentOsEnv`.
4. Add or extend a small runtime config surface so the deployed service can report whether it sees the new value.

Do not stop at step 1. A variable existing in the local shell does not make it live in the deployed backend. New backend env vars are not fully wired until deploy-time sync and runtime visibility are both in place.

## Preferred app-side testing infrastructure

### Headless engine tooling

Use headless engine tooling first when the behavior is local to the engine's algebraic domain model:

```bash
just engine-test
just engine-scenario foreground_transmit_receive
```

Use the live-local engine lane when the same engine story should exercise production-like backend route semantics without launching the app:

```bash
just serve-local
just engine-scenario-local foreground_transmit_receive
just engine-fuzz-local 12345 500
```

`engine-scenario-local` and `engine-fuzz-local` default to `http://localhost:8090/s/turbo` and assume `just serve-local` is already running. If the backend is unavailable, treat connection failure as an environment/setup failure, not a scenario assertion.

Engine fuzz failures are replayable from the artifact path printed by the command, normally under `/tmp/turbo-engine-fuzz/`. Promote a failing seed to a package test, checked-in engine scenario, simulator scenario, or backend proof depending on the owner.

### Simulator and app-side tooling

For distributed app/backend flows that do not require a physical device, prefer this stack:

- checked-in scenario specs in [`scenarios/`](/Users/mau/Development/Turbo/scenarios)
- Swift test execution of `TurboTests/SimulatorScenarioTests`
- `just simulator-scenario <scenario>` or `just simulator-scenario-suite`
- merged diagnostics via `just simulator-scenario-merge`
- strict invariant checking via `just simulator-scenario-merge-strict`
- typed state-machine projections captured in diagnostics snapshots and asserted by scenarios

`just simulator-scenario-suite` is the canonical full run. It executes the dedicated simulator scenario suite with no runtime filter, which means every checked-in `scenarios/*.json` file is exercised automatically.

`just simulator-scenario-suite-hosted-smoke` is the deployed-surface subset. Use it when you want a fast hosted confidence pass without running the entire scenario catalog against `https://staging.beepbeep.to`. It intentionally excludes transport-fault recovery scenarios whose websocket/device-connectivity invariants are only modeled deterministically in the local websocket lane.

`just simulator-scenario-suite-local` is the deterministic local websocket-backed catalog run. It assumes `just serve-local` is already running on `http://localhost:8090/s/turbo`.

The simulator scenario commands are backed by `scripts/run_simulator_scenarios.py`, which owns the temporary runtime config, serializes scenario runs with a repo-local lock, shares the `/tmp/turbo-simulator-test.lock` simulator lane with targeted Swift tests, and retries transient XCTest bootstrap failures. Full catalog runs also allow one catalog-level retry per scenario to absorb hosted timing noise; focused single-scenario runs stay strict. Prefer the `just` recipes over direct `xcodebuild` for the scenario loop.

When you need to debug control-plane correctness without the websocket command path or HTTP hedge, use `just simulator-scenario-http-control ...` or pass `--control-command-transport-policy http-only` directly to `scripts/run_simulator_scenarios.py`. That forces join/leave control commands onto plain HTTP while leaving the rest of the scenario lane unchanged. For ad hoc app-side debugging outside the scenario runner, the same override can be forced with `-TurboDebugControlCommandTransportPolicy http-only` or `TURBO_DEBUG_CONTROL_COMMAND_TRANSPORT_POLICY=http-only`. Keep the default `automatic` policy for normal runs; `http-only` is a debugging/bisection tool, not the shipping default.

`just swift-test-suite` is the supported full `TurboTests` bundle loop. It runs the app-side Swift test bundle with the same serialized simulator lane used by targeted tests and scenario runs, writes an `.xcresult`, and fails if the result bundle reports zero executed tests.

`just swift-test-target <name>` is the supported targeted Swift Testing loop. It resolves the Swift Testing suite, invokes `xcodebuild` with the exact selector, and fails if the requested test name never appears in the output, which prevents the false-green zero-test cases that can happen with direct `-only-testing` invocations against Swift Testing tests in this repo.

If you must use raw `xcodebuild -only-testing`, Swift Testing selectors need the suite type and trailing function parentheses, for example `-only-testing:TurboTests/DeviceTests/audioOutputPreferenceCyclesBetweenSpeakerAndPhone()`. The same selector without `()` can build and report success while selecting zero Swift Testing tests. See [`TESTING.md`](/Users/mau/Development/Turbo/TESTING.md) for the exact selector shape and proof rules.

### Physical-device app tooling

Owner: app install/launch/test harness and Apple/PTT/audio boundary checks.
First proof lane: use engine, Swift, simulator, or backend probes first unless the claim requires real hardware, PushToTalk UI, microphone permission, background/lock-screen behavior, audio-session activation, or actual capture/playback.
Escalation condition: move to devices only after the lower lane that owns shared state is green or inapplicable.
Artifacts: `scripts/device_app.py` writes devicectl JSON and `.xcresult` bundles under `/tmp/turbo-device-app/`; builds use `/tmp/turbo-device-derived-data/`.
Done condition: the app installs/launches on the intended device, or the physical-device test run exits successfully and its `.xcresult` reports a nonzero test count.

| Task | Command |
| --- | --- |
| List connected physical iOS devices | `just device-list` |
| Inspect one device | `just device-info <device>` |
| Build, install, and launch one device | `just device-run <device>` |
| Build, install, and launch every connected physical iOS device | `just device-run-connected` |
| Install an already-built `.app` | `just device-install <device> </path/App.app>` |
| Launch an installed app without rebuilding | `just device-launch <device>` |
| Extract app-container diagnostics from one device | `just device-diagnostics <device>` |
| Extract app-container diagnostics from every connected physical iOS device | `just device-diagnostics-connected` |
| Extract app diagnostics plus system crash logs | `just device-diagnostics-crash-logs <device>` |
| Gather a full device sysdiagnose | `just device-sysdiagnose <device>` |
| Run physical-device Swift tests, excluding UI tests by default | `just device-test <device>` |
| Run one Swift Testing function on a physical device | `just device-test-target <device> <testFunctionName>` |
| Run physical-device UI tests | `just device-ui-test <device>` |

`<device>` accepts the hardware UDID from `xcodebuild -showdestinations`, the devicectl identifier from `just device-list`, the serial number, or the exact device name. If exactly one physical iOS device is connected, device arguments may be omitted. If multiple devices are connected, pass the device explicitly.

`scripts/device_app.py` resolves devicectl's CoreDevice identifier separately from the hardware UDID. devicectl install/launch commands use the CoreDevice identifier; `xcodebuild` build/test destinations use the hardware UDID.

`just device-diagnostics` copies `Library/Application Support/Diagnostics` from the app data container for `com.rounded.Turbo`, writes device/app metadata JSON, and emits a local `beepbeep-diagnostics-tail.log` next to the full copied log. If CoreDevice lists the diagnostics files but the directory transfer fails, the wrapper falls back to copying the listed files one by one before failing the diagnostics pull. Use `just device-sysdiagnose` only when app diagnostics and crash logs are insufficient; sysdiagnose artifacts can be large and slow to collect.

Set `TURBO_DEVICE_ALLOW_PROVISIONING_UPDATES=1` only when a local operator intentionally allows Xcode to create or repair signing assets during a device build or test. Otherwise the wrapper uses the checked-in automatic signing configuration without provisioning side effects.

Use the reliability gates when you need a named confidence level:

- `just reliability-gate-regressions` runs `just engine-test`, focused Swift regressions, Python wrapper syntax checks, fixture smoke checks, protocol static checks, and invariant registry validation.
- `just reliability-gate-smoke` runs those regressions, the hosted smoke scenarios, and strict merged diagnostics.
- `just reliability-gate-full` runs those regressions, the full hosted scenario catalog, and strict merged diagnostics.
- `just reliability-gate-local` runs those regressions, the full local scenario catalog, and strict local merged diagnostics. Start `just serve-local` first.

Use [`fuzz.md`](/Users/mau/Development/Turbo/fuzz.md) for the operator loop and this command map to keep the reliability workflow small:

| Lane | Command | Status | Use when |
| --- | --- | --- | --- |
| Engine package tests | `just engine-test` | Primary | Proving Foundation-only engine reducer, invariant, synthetic media, lifecycle, and transport rules. |
| Headless engine scenario | `just engine-scenario <name>` | Primary | Exercising a named synthetic engine story without backend or simulator startup. |
| Live-local engine scenario/fuzz | `just engine-scenario-local <name>`, `just engine-fuzz-local <seed> <count>` | Primary | Exercising the same engine through `turbo.serveLocal` semantics before app/simulator escalation. |
| Local regression gate | `just reliability-gate-regressions` | Primary | Proving focused code changes before deploy or before deeper scenario work. |
| Local overnight fuzz | `just reliability-fuzz-local-overnight <seed> <count>` | Primary | Broad local reliability sweep: headless engine fuzz first, then simulator fuzz with strict diagnostics and engine trace replay. |
| Hosted smoke gate | `just reliability-gate-smoke` | Primary | Proving simulator-backed hosted control-plane behavior before a risky release. |
| Staging-grade verified deploy | `just deploy-staging-verified` | Primary | Day-to-day verified deploy path. Today it still targets the hosted production base URL. |
| Production preflight | `just production-preflight` | Primary | Run the expensive local proof gate before a production deploy. |
| Production deploy | `just deploy-production` | Primary | Run the strict preflight, deploy, then prove the live hosted canary and SLOs. |
| Postdeploy verification | `just postdeploy-check` | Primary | A deploy already happened, or production feels flaky and needs a fresh canary. |
| Reliability intake | `just reliability-intake`, `just reliability-intake-shake` | Primary | Starting from a physical-device, debug, TestFlight, production-like, or shake-to-report issue. Writes human/JSON diagnostics and a replay draft when possible. |
| Lower-level diagnostics merge | `just diagnostics-merge-pair` or `scripts/merged_diagnostics.py --json` | Building block | Reading merged diagnostics directly when you do not need the full intake artifact. |
| Production replay | `just production-replay` | Primary when diagnostics JSON exists | Turning field evidence into a local replay or scenario draft. |
| Protocol model check | `just protocol-model-checks` | Primary for protocol changes | Checking distributed interleavings and the matching Swift property tests. |
| Full hosted/local gates | `just reliability-gate-full`, `just reliability-gate-local` | Primary but expensive | Broad confidence after shared state-machine or backend contract changes. |
| Synthetic probe and SLO dashboard | `just synthetic-conversation-probe`, `just slo-dashboard` | Building blocks | Running only one half of `postdeploy-check` or combining extra SLO sources. |
| Route probe | `just route-probe`, `just route-probe-local` | Diagnostic/building block | Debugging route contract details or local websocket behavior. The synthetic conversation probe wraps this for the release canary. |
| Backend stability probe | `just backend-stability-probe` | Diagnostic | Separating hosted route availability from app/device behavior, especially for Unison Cloud escalation. It covers bootstrap, Beep list reads, and lightweight authenticated writes (`auth`, `device-register`, `beeps-incoming`, `beeps-outgoing`, `presence-heartbeat`, `telemetry-events`). |
| WebSocket stability probe | `just websocket-stability-probe` | Diagnostic | Measuring long-lived hosted websocket continuity separately from the full simulator scenario lane. Opens two authenticated sockets, keeps app-like websocket pings enabled, and can layer periodic heartbeats / telemetry writes while recording unexpected closes. |
| Hosted backend client probe | `just hosted-backend-client-probe` | Diagnostic | Exercising the real iOS `TurboBackendClient` / `URLSessionWebSocketTask` path against hosted backend infrastructure, with periodic heartbeats and telemetry writes plus a JSON artifact. |
| Retired production probes | older overlapping hosted probe recipes | Removed | Replaced by `postdeploy-check`; use `route-probe` for lower-level route-contract debugging. |
| Legacy APNs bridge helpers | `just ptt-apns-bridge`, `just ptt-apns-worker` | Diagnostic/legacy | Debugging old interim wake paths. Prefer the current deployed wake path and diagnostics surface when available. |

Agent workflow rules for these lanes:

- Prefer `just` recipes over spelling out lower-level SwiftPM, xcodebuild, Python, or UCM commands unless debugging the wrapper itself.
- When a command prints an artifact directory, keep that path in the handoff or final note.
- When a fuzz or scenario failure is stable, promote it into the lowest deterministic lane that still captures the owner.
- Do not use `reliability-gate-full` or physical devices as a substitute for choosing ownership; broad gates confirm, they do not localize.
- If local backend commands fail before scenario assertions run, fix or restart `just serve-local` before changing app logic.

Use `just synthetic-conversation-probe` when you want a production-shaped
two-device control-plane canary without launching the app. It runs the semantic
route probe with synthetic caller/callee identities, requires the websocket,
receiver-ready, begin-transmit, push-target, and end-transmit checks to be
present, and writes per-iteration artifacts plus
`synthetic-conversation-probe.json` for comparison across runs.

Use `just slo-dashboard <synthetic-conversation-probe.json>` to turn probe
evidence into a static SLO report. The dashboard writes `slo-dashboard.json`,
`slo-dashboard.md`, and `reproduce.sh`, then fails when product-facing
conversation objectives breach their thresholds. The script can also read
backend stability probe JSON and merged diagnostics JSON directly when a report
needs to combine route health with invariant health.

Use `just protocol-model-checks` when a change touches core conversation
protocol rules. It validates the TLA+ communication model, runs TLC with the
configured safety invariants when `tla2tools.jar` is available, and runs the
Swift property tests for conversation projection and transport-fault planning.
Set `TLA2TOOLS_JAR` or pass the jar path as the first recipe argument when the
jar is not at `/tmp/tla2tools.jar`.

## Environment helpers

### `direnv`

Use `direnv exec . ...` when running commands that depend on repo-local environment configuration, especially APNs/PTT helper flows.
This is also the default for Codex/macOS GUI-app initiated commands that need `.envrc` secrets, because GUI app processes do not reliably inherit the interactive shell's direnv-expanded environment.

Cloudflare Analytics Engine access requires `TURBO_CLOUDFLARE_ACCOUNT_ID` and `TURBO_CLOUDFLARE_ANALYTICS_READ_TOKEN`, so telemetry reads should be run like:

```bash
direnv exec . python3 scripts/query_telemetry.py --hours 2 --user-handle @mau --limit 100
direnv exec . python3 scripts/merged_diagnostics.py --telemetry-hours 2 @mau @bau
```

### Diagnostics infrastructure

Debug builds publish structured diagnostics, and the backend supports exact-device diagnostics reads, including simulator identities. Agents should treat `scripts/merged_diagnostics.py` as the default entrypoint for debugging a two-device report. It is intentionally a merger over multiple sources, not "just telemetry" and not "just backend diagnostics."

Keep the two observability lanes separate:

- Cloudflare telemetry is the compact event stream for timing markers, invariant violations, route failures, production alerts, and shake-to-report pivots. Use it when you need the recent high-signal event timeline.
- Unison backend diagnostics are the latest full snapshot/transcript surface. Use it when you need routine state captures, the full local transcript, audio packet logs, playback scheduling details, or exact app state snapshot for a device. Debug builds keep routine state captures local and upload them through diagnostics snapshots; raw state-capture telemetry is only for an explicit short-session opt-in.

This makes the standard loop:

1. reproduce
2. run the scenario or probe, when the bug can be reproduced without physical devices
3. merge diagnostics with the single merged diagnostics command
4. inspect the merged timeline, backend latest transcript anchors, source warnings, and invariant violations

Prefer that over guessing from screenshots or manual tap-through notes.

For physical-device debugging, the expected agent loop is:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 1 @mau @bau
```

For normal intake from a human report, prefer the facade first:

```bash
just reliability-intake @mau @bau
just reliability-intake-shake @mau <incidentId> @bau
```

It writes a timestamped artifact under `/tmp/turbo-reliability-intake/` with a
summary, human merged diagnostics, JSON merged diagnostics, and a best-effort
production replay draft when there are enough participants. Use the lower-level
`merged_diagnostics.py` command directly when you need custom flags or a quick
terminal read.

For script-level regression work on the merged pair/convergence lane, use:

```bash
python3 scripts/test_merged_diagnostics.py
```

That test file is the focused proof surface for:

- `currentViolations` versus `historicalViolations` classification
- merged pair detectors such as `pair.one_sided_connectable_session` and `pair.pending_request_receiver_not_observed`
- fixture-backed downstream consumers such as production replay conversion and SLO dashboard summaries

Checked-in replay fixtures under [`fixtures/production_replay/`](/Users/mau/Development/Turbo/fixtures/production_replay) are the canonical downstream artifacts for this lane. In particular:

- [`merged_diagnostics_mixed.json`](/Users/mau/Development/Turbo/fixtures/production_replay/merged_diagnostics_mixed.json) covers one current pair violation plus one historical local violation
- [`merged_diagnostics_pair_matrix.json`](/Users/mau/Development/Turbo/fixtures/production_replay/merged_diagnostics_pair_matrix.json) covers multiple current pair violations in one merged report

For an agent investigation where the result will be saved and searched repeatedly, prefer this default:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 2 --telemetry-limit 500 --full-metadata @mau @bau > /tmp/turbo-merged-diagnostics.txt
```

That command:

- fetches backend latest snapshots/transcripts by default
- merges Cloudflare telemetry when credentials are available
- keeps complete telemetry metadata in the human timeline
- bounds backend route waits so a slow latest-snapshot read does not block the whole investigation
- produces grep-friendly text for repeated searches during the debugging loop

Use `--insecure` only when local Python certificate roots block Cloudflare queries during development:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 1 --insecure @mau @bau
```

This is the right workaround for the recurring local failure where the diagnostics fetch reaches Cloudflare telemetry but Python cannot verify the local certificate chain. Treat it as scoped to that debugging read: rerun the diagnostics command with `--insecure`, note that TLS verification was relaxed for the local fetch, and keep the rest of the investigation unchanged. Prefer the `just` diagnostics wrappers when they fit because the common debug recipes already expose/default the `insecure` argument for this local-development case.

Use `--json` when you need to script over the result:

```bash
python3 scripts/merged_diagnostics.py --json --backend-timeout 8 --telemetry-hours 1 @mau @bau > /tmp/turbo-merged.json
```

For downstream replay and dashboard smoke against a checked-in merged artifact:

```bash
python3 scripts/convert_production_replay.py --merged-diagnostics-json fixtures/production_replay/merged_diagnostics_pair_matrix.json --output-dir /tmp/turbo-production-replay-pair-matrix --name fixture_production_replay_pair_matrix
python3 scripts/slo_dashboard.py --merged-diagnostics-json fixtures/production_replay/merged_diagnostics_pair_matrix.json --output-dir /tmp/turbo-slo-dashboard-pair-matrix --name pair-matrix-smoke
```

Default flag guidance:

- Use `--backend-timeout 8` by default for physical-device debugging. Raise it to `15` if the backend is healthy but slow; lower it only when you explicitly want telemetry-first behavior.
- Use `--telemetry-hours 2` by default for manual device sessions. Narrow to `1` for a fresh repro; expand to `4` or more when the user has been testing for a long time.
- Use `--telemetry-limit 500` by default when saving an artifact for grep. Lower limits are fine for quick status checks; intense sessions can need more rows.
- Use `--full-metadata` by default when redirecting to a file. Skip it for quick terminal reads where compact output is easier.
- Do not use `--insecure` as a universal default. It is acceptable in local development when certificate roots are broken, but it disables TLS verification for HTTPS requests.
- Do not use `--no-telemetry` unless you are intentionally isolating backend latest snapshots/transcripts or Cloudflare credentials are broken.
- Do not use `--include-heartbeats` unless presence heartbeat cadence is the suspected bug.
- Use `--json` for automation, not as the default human debugging artifact.

Useful `merged_diagnostics.py` flags:

| Flag | Use when |
| --- | --- |
| `--base-url <url>` | Reading diagnostics from a non-default backend, such as a local or staging service. |
| `--backend-timeout <seconds>` | Bounding each backend latest/invariant/wake diagnostics request so telemetry can still return when the backend is slow. Use `8` or `15` for normal development. |
| `--device <handle=device-id>` | Fetching an exact device snapshot instead of the latest snapshot for a handle. This is common for simulator identities and scenario artifacts. Repeat once per handle when needed. When you use only exact `--device` mappings, the telemetry merge stays scoped to those device IDs instead of widening back out to the full handle history. |
| `--json` | Feeding merged diagnostics into a script, counting events, comparing transport digests, or attaching a machine-readable artifact. |
| `--fail-on-violations` | CI/scenario/debug gates where current typed invariant violations should make the command fail. Historical-only violations stay visible in output/JSON but do not fail the command. |
| `--full-metadata` | Inspecting complete Cloudflare telemetry metadata in the human timeline instead of the compact truncated view. |
| `--include-telemetry` | Explicitly enabling Cloudflare telemetry merge. This is already the default. |
| `--no-telemetry` | Reading only backend latest diagnostics snapshots/transcripts, useful when Cloudflare credentials are absent, slow, or irrelevant. |
| `--telemetry-hours <hours>` | Expanding or narrowing the Cloudflare lookback window. Use a small window for fresh physical-device reports; expand when debugging a long session. |
| `--telemetry-limit <n>` | Raising the maximum Cloudflare rows merged into the report. Increase this for intense sessions with many high-signal events or an explicitly opted-in raw state-capture telemetry run. |
| `--include-heartbeats` | Including backend presence heartbeat telemetry. Leave this off unless heartbeat cadence itself is the suspected bug. |
| `--telemetry-dataset <name>` | Querying a non-default Analytics Engine dataset. Rare outside telemetry migration/testing. |
| `--insecure` | Development-only workaround for local Python certificate-root problems when querying HTTPS/Cloudflare. |

Do not ask the tester to tap "Upload diagnostics" as the normal loop. In current debug builds, the app should automatically publish the latest compact transcript after high-signal activity, with local byte-budget preflight and fallback to smaller diagnostics before attempting an oversized upload. The app shows a debug diagnostics upload status while the upload is queued, deferred by live audio, uploading, uploaded, or failed. Manual upload is a fallback for old builds, a suspected auto-publish regression, or one-off local investigation.

Interpret source warnings carefully:

- missing Cloudflare credentials means the command can still use backend latest snapshots, but the compact high-volume timeline is absent
- missing backend latest snapshot means the command can still show telemetry, but full transcript/audio-packet evidence is absent
- missing backend latest snapshot on a current debug build after fresh activity is itself a bug in auto-publish or backend diagnostics storage
- a backend timeout should not block the whole investigation; use the telemetry portion immediately, then probe backend health separately
- if the app shows auto-upload failed or never leaves queued/deferred after audio is idle, use `just device-diagnostics <device>` or `just device-diagnostics-connected` as the local fallback

When debugging audio quality or packet loss, backend latest snapshots matter. Telemetry can show that a transmit began or that an invariant fired, but the full transcript is where agents should look for `Captured local audio buffer`, `Enqueued outbound audio chunk`, transport digests, `Audio chunk received`, and `Playback buffer scheduled`.

Do not put every audio packet into Cloudflare telemetry by default. Packet-level audio evidence belongs in backend latest diagnostics, and it should usually be budgeted or summarized. If a bug needs deeper accounting, add a debug/test-gated diagnostic mode that emits compact sequence/digest/timing facts plus transmit-end totals, then keep using `merged_diagnostics.py` as the single read path.

Scenario runs are stricter than normal app debugging:

- normal debug builds auto-publish the latest compact diagnostics transcript opportunistically after a short coalescing window and record upload byte size/fallback mode in diagnostics
- routine debug state captures stay in local/backend diagnostics; only explicitly opted-in raw state-capture telemetry should create high-volume Cloudflare timelines
- simulator scenarios publish explicit scenario-tagged diagnostics artifacts and verify exact-device reads against those artifacts
- scenario view models disable automatic diagnostics publishing so scenario verification does not get overwritten by later background uploads from the same simulator identity
- merged diagnostics now also parse explicit `INVARIANT VIOLATIONS` sections, derive pair-level violations, support `--json`, include Cloudflare telemetry by default when credentials are available, tolerate missing latest backend snapshots, and can fail non-zero with `--fail-on-violations`

Use Cloudflare telemetry queries for high-volume debugging:

```bash
direnv exec . python3 scripts/query_telemetry.py --hours 2 --user-handle @mau --limit 100
direnv exec . python3 scripts/merged_diagnostics.py --telemetry-hours 2 @mau @bau
```

Telemetry merging requires `TURBO_CLOUDFLARE_ACCOUNT_ID` and `TURBO_CLOUDFLARE_ANALYTICS_READ_TOKEN`. Without those credentials, merged diagnostics still works from the backend latest snapshot. If a physical device is on an older build or the latest backend snapshot is missing, merged diagnostics prints a source warning and still emits the telemetry timeline.
If local Python certificate roots are stale, add `--insecure` to Cloudflare telemetry queries or merged diagnostics during development.
If a backend diagnostics route is slow or unhealthy, `merged_diagnostics.py` bounds each backend request with `--backend-timeout` so the command can still return telemetry and source warnings.

If diagnostics uploads appear to be stressing hosted Unison storage, clear the authenticated user's latest diagnostics anchor after deploying the current backend:

```bash
curl -X POST -H 'x-turbo-user-handle: @mau' -H 'Authorization: Bearer @mau' https://staging.beepbeep.to/v1/dev/diagnostics/clear
```

If a known exact-device diagnostics row needs to be removed, clear it by key without materializing the stored payload:

```bash
curl -X POST -H 'x-turbo-user-handle: @mau' -H 'Authorization: Bearer @mau' https://staging.beepbeep.to/v1/dev/diagnostics/clear/<device-id>
```

Do not use `reset-all` just to clear diagnostics; it also clears product/session state.

Use the backend stability probe when production bootstrap routes appear intermittently unavailable:

```bash
python3 scripts/backend_stability_probe.py --iterations 30 --timeout 8 --handle @mau
just backend-stability-probe https://staging.beepbeep.to @mau 30 8
```

The probe repeatedly checks `/v1/health`, `/v1/config`, `/v1/auth/session`, `/v1/devices/register`, `/v1/beeps/incoming`, `/v1/beeps/outgoing`, `/v1/presence/heartbeat`, and `/v1/telemetry/events`, reports per-request latency/timeouts, and exits non-zero if any request fails. Use it when simulator-hosted scenarios are timing out on Beep refreshes, not just bootstrap or write paths. This is the preferred artifact for Unison Cloud escalation because it separates route availability from app/device behavior while still exercising the lightweight authenticated reads/writes that simulator-hosted runs depend on.

When the suspected problem is websocket continuity rather than plain route availability, use:

```bash
just websocket-stability-probe https://staging.beepbeep.to @quinn @sasha 90 20 0
```

That probe opens two authenticated websocket sessions with unique simulator-style device IDs, holds them open for the requested duration, uses the same 20s websocket ping cadence as the app by default, and optionally layers periodic `presence/heartbeat` and `telemetry/events` writes. It should be the first lower-level proof when the app reports websocket `idle` / reconnect churn but `route-probe` and `backend-stability-probe` are green.

When the lower-level Python websocket probe is green but the app still looks suspicious, use the client-native probe:

```bash
just hosted-backend-client-probe https://staging.beepbeep.to 60 20 20
```

That runs a single opt-in Swift `@Test` through the actual `TurboBackendClient` / `URLSessionWebSocketTask` path, bootstraps auth + device registration + initial presence heartbeat, keeps the socket open for the requested duration, layers periodic `presence/heartbeat` and `telemetry/events` writes, and writes a JSON artifact to `/tmp/turbo-debug/hosted_backend_client_probe_latest.json` by default. The wrapper uses a dedicated `iPhone 17 Pro` simulator and removes its temporary runtime-control file on exit so other automated tests do not inherit the probe-only backend-bootstrap suppression. Use it when you need to distinguish Python-lower-level websocket stability from app-client websocket stability.

When hosted simulator scenarios report `NSURLErrorDomain -1001` or `-1005`, use `just backend-stability-probe` or `just route-probe` before blaming schema drift or rotating the environment. If the raw probes pass, keep debugging the simulator/app transport lane instead of treating the backend environment as corrupt.

`just route-probe` should be treated as a semantic probe, not just a route-existence check. In particular, diagnostics upload/latest routes should round-trip the exact `deviceId` and `appVersion` that were just written.

Use `just route-probe-local` when iterating on the local websocket-backed backend. It exercises the same semantic checks against `ws://` / `http://` routes instead of the deployed `wss://` / `https://` surface.

Local-only transport-fault scenarios belong in the local websocket lane. The scenario runner enforces `"requiresLocalBackend": true`, so hosted runs fail fast if you explicitly ask for a local-only scenario without a local base URL.
