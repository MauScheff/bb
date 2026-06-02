# Tooling Guide

Operational command reference for `/Users/mau/Development/bb`. Use [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md) for proof strategy; use this file for active commands.

## Active Shape

| Surface | Path or owner | Primary commands |
| --- | --- | --- |
| Backend runtime | [`backend`](/Users/mau/Development/bb/backend) | `just beepbeep-backend-gate`, `just beepbeep-backend-production-gate`, `just self-hosted-serve` |
| Unison kernel | local Unison project `bb/main`, namespace `beepbeep.*` | `just kernel-test`, `just kernel-fuzz`, `just kernel-corpus-json` |
| Backend relay module | [`backend/relay`](/Users/mau/Development/bb/backend/relay) | `just relay-test`, `just gce-relay-deploy-dry-run`, `just gce-relay-deploy` |
| iOS client | [`client/ios`](/Users/mau/Development/bb/client/ios) | `just swift-test-target`, `just swift-test-suite`, device recipes |
| Engine core | [`client/ios/Packages/TurboEngine`](/Users/mau/Development/bb/client/ios/Packages/TurboEngine) | `just engine-test`, `just engine-scenario`, `just engine-fuzz-local` |
| Scenarios | [`shared/scenarios`](/Users/mau/Development/bb/shared/scenarios) | `just simulator-scenario*`, `just simulator-scenario-suite-self-hosted` |
| Invariants/contracts | [`shared/invariants`](/Users/mau/Development/bb/shared/invariants), [`shared/contracts`](/Users/mau/Development/bb/shared/contracts) | reliability gates, diagnostics merge, focused tests |
| Operational scripts | [`tools/scripts`](/Users/mau/Development/bb/tools/scripts), [`backend/scripts`](/Users/mau/Development/bb/backend/scripts) | invoked through `just` unless debugging a wrapper |

Canonical deployed base URL:

```text
https://api.beepbeep.to
```

The old `/Users/mau/Development/Turbo` checkout is the recovery archive. Do not add new active backend behavior to the old `turbo.*` Cloud path unless explicitly doing archaeology or maintenance.

## Selection Rules

- Start at the narrowest proof lane that owns the behavior.
- Prefer `just` recipes over lower-level SwiftPM, Xcode, Python, Cargo, Docker, or UCM commands.
- Backend/shared truth is backend-owned unless the owner has been proven elsewhere.
- Use simulator scenarios only when the app target, backend route/projection behavior, scenario DSL, or merged diagnostics must be exercised.
- Use physical devices only for real Apple PushToTalk, permissions, backgrounding, audio-session activation, microphone capture, speaker output, and hardware-only behavior.
- Keep fuzz seeds, scenario names, artifact paths, and exact commands in handoffs or final notes when a failure matters.

## Backend Reliability

| Need | Command | Done condition |
| --- | --- | --- |
| Pure Unison kernel proof | `just kernel-fuzz` | `beepbeep.tests` passes in `bb/main` |
| Compiled kernel invocation timing | `just kernel-invocation-audit` | `/tmp/bb-kernel-invocation-audit.json` records per-case `run.compiled` elapsed milliseconds |
| Resident kernel worker groundwork | `TURBO_KERNEL_WORKER_MODE=resident` | opt-in only until UCM worker output is flush-capable; the VM default remains `per-command` |
| Export replay corpus | `just kernel-corpus-json /tmp/turbo-kernel-corpus.json` | JSON corpus is written and parseable |
| Rust runtime tests | `just rust-runtime-test` | `beepbeep-runtime` tests pass |
| Runtime/Postgres integration | `just runtime-postgres-integration` | `/tmp/turbo-rust-runtime-integration.json` reports success |
| Local HTTP process probe | `just self-hosted-http-probe` | `/tmp/turbo-self-hosted-http-probe.json` reports success |
| Local websocket probe | `just self-hosted-websocket-probe` | `/tmp/turbo-self-hosted-websocket-probe.json` reports success |
| Local backend gate | `just beepbeep-backend-gate` | `/tmp/beepbeep-backend-reliability-gate.json` reports no failed step |
| Dry-run backend gate | `just beepbeep-backend-gate-dry-run local 123 3 /tmp/beepbeep-backend-gate-dry.json` | gate orchestration is valid without running heavy steps |
| Hosted production gate | `just beepbeep-backend-production-gate https://api.beepbeep.to` | production route, websocket, fuzz, and probe evidence pass |
| Release readiness | `just beepbeep-backend-cutover-readiness` | machine-readable readiness artifact has no blocking missing evidence |

Promote production bugs downward: hosted failure -> hosted probe -> self-hosted probe/fuzz -> Rust runtime proof -> Unison kernel proof.

## Local Backend

Start dependencies when a proof needs Postgres/Redis:

```bash
just self-hosted-up
```

Run the app-compatible local runtime:

```bash
just self-hosted-serve 127.0.0.1:8091
```

Use the self-hosted scenario suite against that runtime:

```bash
just simulator-scenario-suite-self-hosted http://127.0.0.1:8091/s/turbo
```

Stop dependencies with:

```bash
just self-hosted-down
```

Some older local scenario recipes still default to `http://localhost:8090/s/turbo`; pass an explicit base URL for the active runtime unless the recipe name says `self-hosted`.

## Deploy And Production

The active deployed target is `https://api.beepbeep.to`.

| Need | Command |
| --- | --- |
| VM deploy package/proof, dry run | `just gce-self-hosted-deploy-dry-run <gcp-project>` |
| VM deploy | `just gce-self-hosted-deploy <gcp-project>` |
| Relay VM deploy package/proof, dry run | `just gce-relay-deploy-dry-run <gcp-project>` |
| Relay VM deploy | `just gce-relay-deploy <gcp-project>` |
| Hosted synthetic canary | `just postdeploy-check https://api.beepbeep.to` |
| Hosted backend stability | `just backend-stability-probe https://api.beepbeep.to` |
| Hosted websocket stability | `just websocket-stability-probe https://api.beepbeep.to` |
| Hosted simulator smoke | `just simulator-scenario-suite-hosted-smoke` |

API VM deploys are registry-backed. The runtime image is
`europe-west6-docker.pkg.dev/<project>/turbo/turbo-self-hosted:<git-sha>` and
uses registry BuildKit cache at
`europe-west6-docker.pkg.dev/<project>/turbo/turbo-self-hosted:buildcache`.
Live deploys require a clean git worktree unless `--allow-dirty` or
`TURBO_GCE_ALLOW_DIRTY=1` is explicitly set; allowed dirty deploys get a
`-dirty-<timestamp>` image tag when the tag is not specified.

The packaged runtime keeps `TURBO_KERNEL_WORKER_MODE=per-command` as the safe
default. A resident Rust worker adapter and `resident-kernel-worker.uc` compile
target exist, but UCM currently buffers `printLine` output until stdin closes;
do not default live deploys to `resident` until that protocol has a
flush-capable output path.

The API runtime image depends on `backend/relay-protocol`, not the full relay
server crate. Relay deploys use a separate image,
`europe-west6-docker.pkg.dev/<project>/turbo/beepbeep-relay:<git-sha>`, and
target `turbo-relay-1`. The relay deploy script refuses to replace an active
`turbo-relay` systemd service unless `--replace-systemd-service` is passed.

Do not use removed legacy Cloud deploy recipes as the normal release path. If old Cloud behavior must be inspected, use the archive checkout and document that the work is archival.

## Client And Engine

| Need | Command |
| --- | --- |
| Engine package tests | `just engine-test` |
| Headless engine scenario | `just engine-scenario <name>` |
| Engine trace replay | `just engine-trace-replay <trace.json>` |
| Engine corpus fuzz replay | `just engine-fuzz-corpus` |
| Targeted Swift test | `just swift-test-target <name>` |
| Full Swift test suite | `just swift-test-suite` |
| Hosted simulator scenario | `just simulator-scenario <name>` |
| Strict hosted diagnostics merge | `just simulator-scenario-merge-strict` |
| Self-hosted simulator suite | `just simulator-scenario-suite-self-hosted http://127.0.0.1:8091/s/turbo` |

For Swift Testing selectors, prefer `just swift-test-target`. Raw `xcodebuild -only-testing` can report false success when the selector omits the trailing `()`.

## Physical Devices

Use physical devices only after lower lanes are green or inapplicable.

| Need | Command |
| --- | --- |
| List connected devices | `just device-list` |
| Build/install/launch one device | `just device-run <device>` |
| Run physical-device Swift tests | `just device-test <device>` |
| Run one physical-device test | `just device-test-target <device> <testFunctionName>` |
| Pull app diagnostics | `just device-diagnostics <device>` |
| Pull diagnostics from every connected device | `just device-diagnostics-connected` |
| Pull diagnostics plus crash logs | `just device-diagnostics-crash-logs <device>` |
| Gather sysdiagnose | `just device-sysdiagnose <device>` |

`<device>` may be a hardware UDID, CoreDevice identifier, serial number, or exact device name. If exactly one physical iOS device is connected, most device recipes can infer it.

## Reliability And Fuzzing

| Confidence level | Command | Use when |
| --- | --- | --- |
| Focused regression gate | `just reliability-gate-regressions` | before merging focused app/engine/tooling changes |
| Hosted smoke gate | `just reliability-gate-smoke` | before trusting hosted control-plane behavior |
| Full hosted gate | `just reliability-gate-full` | after shared state-machine or backend contract changes |
| Local full gate | `just reliability-gate-local` | when local runtime exercises the relevant distributed behavior |
| Self-hosted overnight fuzz | `just reliability-fuzz-self-hosted-overnight <seed> <count>` | broad Rust/runtime confidence |
| Simulator fuzz | `just simulator-fuzz-local <seed> <count> <base>` | generated app/backend interleavings |
| Production/shake intake | `just reliability-intake ...`, `just reliability-intake-shake ...` | field evidence to replayable artifacts |
| Production replay | `just production-replay <merged-diagnostics.json>` | convert field diagnostics into local proof material |
| Protocol model checks | `just protocol-model-checks` | reconnect, stale snapshot, lease, wake, or ownership protocol changes |

Fuzz failures are useful only when replayable. Save the seed, count, base URL, artifact directory, and first failing invariant.

## Generated Files

Generated caches and proof artifacts belong outside source control:

- Cargo/Swift build outputs: `target/`, `.build/`, `.xcresult`
- Python caches: `__pycache__/`
- large model-check states: `shared/specs/tla/states/`
- proof artifacts: `/tmp/turbo-*`, `/tmp/beepbeep-*`, `/tmp/bb-*`

It is safe to remove generated files inside `/Users/mau/Development/bb` and old BeepBeep proof artifacts under `/tmp` when they are no longer needed. Do not delete files from `/Users/mau/Development/Turbo` while using it as the recovery archive.
