# BeepBeep

BeepBeep is an iOS Push-to-Talk app backed by a Rust control-plane runtime and a pure Unison kernel.

The app owns Apple PushToTalk, audio, local projection, and user interaction. The backend owns shared truth: identity, devices, Beeps, Conversation membership, readiness, wake targeting, websocket signaling, and Talk Turn ownership. The backend is the control plane, not the media plane.

Canonical hosted backend:

```text
https://api.beepbeep.to
```

## Layout

| Area | Path |
| --- | --- |
| iOS app and tests | `client/ios/` |
| Engine package | `client/ios/Packages/TurboEngine` |
| Rust backend runtime | `backend/runtime` |
| Fast relay module | `backend/relay` |
| Backend infra/scripts/specs | `backend/infra`, `backend/scripts`, `backend/specs` |
| Shared contracts, invariants, scenarios, fixtures | `shared/` |
| Cross-cutting tools | `tools/scripts/` |
| Organized docs and historical reference | `docs/` |
| Handoffs and durable notes | `handoffs/`, `journal/` |

The old `/Users/mau/Development/Turbo` checkout is the recovery archive. It is not required for normal work in this repo.

## Primary Commands

| Need | Command |
| --- | --- |
| Backend reliability gate | `just beepbeep-backend-gate` |
| Backend production gate | `just beepbeep-backend-production-gate` |
| Backend cutover readiness | `just beepbeep-backend-cutover-readiness` |
| Rust runtime tests | `just rust-runtime-test` |
| Relay tests | `just relay-test` |
| Engine tests | `just engine-test` |
| Swift app test suite | `just swift-test-suite` |
| One Swift test | `just swift-test-target <name>` |
| One simulator scenario | `just simulator-scenario <name>` |
| Reliability intake | `just reliability-intake @mau @bau` |

## Proof Ladder

Use the narrowest lane that exercises the owner:

1. `just engine-test` or `just engine-scenario <name>` for engine-owned rules.
2. `just rust-runtime-test` or `just beepbeep-backend-gate` for backend runtime/kernel rules.
3. `just swift-test-target <name>` for app projection or adapter behavior.
4. `just simulator-scenario <name>` for distributed app/backend journeys.
5. Physical-device checks only for Apple PushToTalk, microphone, lock/background wake, audio session activation, and real capture/playback.

## Agent Entry

Agents start from `AGENTS.md`, use `WORKFLOW.md` for the proof model, `TOOLING.md` for commands, and `GLOSSARY.md` for product/domain language.

Useful docs are organized under `docs/`; historical docs are kept as reference, but active work should route through `client/ios`, `backend`, `shared`, and `tools`.
