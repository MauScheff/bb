# BeepBeep

BeepBeep is an iOS Push-to-Talk app backed by a Rust control-plane runtime and a pure Unison kernel.

The app owns Apple PushToTalk, audio, local projection, and user interaction. The backend owns shared truth: identity, devices, Beeps, Conversation membership, readiness, wake targeting, signaling, and Talk Turn ownership. The backend is the authoritative control plane, never the live media plane.

Canonical hosted production endpoints:

```text
API/control plane: https://api.beepbeep.to
media relay:       relay.beepbeep.to:443
```

The API VM and relay VM are separate on purpose. The API endpoint owns HTTPS
through nginx on TCP `443` and runtime QUIC control on UDP `443`. The relay
endpoint owns QUIC packet media on UDP `443` plus TCP/TLS fallback on TCP
`443`.

Transport model:

| Class | Legal lanes |
| --- | --- |
| Live media | Direct QUIC datagrams, Fast Relay QUIC datagrams, Fast Relay TCP/TLS ordered fallback |
| Hints | Direct QUIC control, Fast Relay QUIC control, runtime control when available |
| Authoritative control | Rust runtime control selected as runtime QUIC, runtime TLS, or HTTP bootstrap/recovery |

Runtime control is not a live media lane. Backend `audio-chunk` control signals
are rejected as invalid live media rather than played as a hidden fallback.
Diagnostics lane forcing is local test policy: it selects a sender lane for an
epoch, and the peer adapts to any valid current-epoch media lane without
changing backend truth.

Runtime config (`GET /v1/config`) advertises the control-lane contract:
`runtimeControl.preference`, `runtimeControl.quic`, `runtimeControl.tls`, and
`runtimeControl.http`. The client resolves the requested runtime-control policy
to an effective lane and records the fallback reason when the preferred
persistent lane is unavailable. The QUIC control ALPN is
`beep-runtime-control-v1`.
Runtime QUIC/TLS command failures recover through runtime HTTP; WebSocket
command compatibility is retired from the default runtime and is available only
behind the explicit `TURBO_RUNTIME_WEBSOCKET_COMPATIBILITY_ENABLED=true`
operator switch for legacy recovery.

Persistent runtime control streams bind identity from the first valid command
frame: `userId` or `userHandle` plus `deviceId`. Later frames with a different
identity are rejected before they can mutate backend truth.

## Layout

| Area | Path |
| --- | --- |
| iOS app and tests | `client/ios/` |
| Engine package | `client/ios/Packages/TurboEngine` |
| Rust backend runtime | `backend/runtime` |
| Fast relay module | `backend/relay` |
| Landing page and waitlist function | `landing/` |
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
