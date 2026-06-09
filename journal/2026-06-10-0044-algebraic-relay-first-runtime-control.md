# Journal 2026-06-10 00:44

## Summary

Implemented the algebraic relay-first media and runtime-control model.

Runtime now owns authoritative control through explicit QUIC/TLS/HTTP control lanes. Live media is restricted to Direct QUIC datagrams, Fast Relay QUIC datagrams, or Fast Relay TLS stream fallback. Runtime WebSocket is retired by default and kept only behind an explicit compatibility escape hatch.

## Problem

The Rust runtime migration reintroduced failures that the older control plane had already made rare: stale projections, lane flapping, missed foreground notifications, silent media turns, and stuck Push-to-Talk state. The underlying issue was not one bug. Media, hints, runtime control, relay paths, and diagnostics overrides were overlapping concepts without a single lawful transport model.

Concurrent fanout also added pressure to the live audio path, especially with diagnostics and encryption enabled. It improved some failure cases but made startup and ordered backlog behavior harder to reason about.

## Design Formulation

Transport is now modeled by closed axes:

- `Endpoint`: peer, fast relay, runtime.
- `Mechanism`: QUIC datagram, QUIC control, TLS stream, HTTP request.
- `PayloadClass`: live media, hint, authoritative command, bootstrap, diagnostics.

Legal lanes are explicit:

- `MediaLane`: `directQuicDatagram`, `fastRelayQuicDatagram`, `fastRelayTlsStream`.
- `HintLane`: direct, relay, or runtime control where non-authoritative hints are legal.
- `AuthoritativeControlLane`: `runtimeQuicControl`, `runtimeTlsControl`, `runtimeHttpRequest`.

Media epochs own live delivery truth:

- `available` means a lane can be tried.
- `active` requires current-epoch delivery proof.
- Rescue is sequential and bounded.
- Runtime never carries live audio.
- WebSocket is not part of the current transport model.

## What Changed

- Added proof-driven media epoch and lane state to the engine/app model.
- Replaced fanout/shadow semantics with primary plus sequential rescue.
- Made path badge projection proof-based during live transmit/receive.
- Added diagnostics lane override state for media and runtime control.
- Added bounded receiver dedupe/playout window and ordered-continuity behavior for TLS fallback.
- Added runtime control protocol, shared stream handling, TLS listener, and QUIC listener modules.
- Wired production runtime config for optional QUIC/TLS control listeners and advertised endpoints.
- Retired runtime WebSocket by default through `TURBO_RUNTIME_WEBSOCKET_COMPATIBILITY_ENABLED`.
- Added relay QUIC active-migration config and diagnostics exposure.
- Updated docs, invariant registry, and app contract manifest to describe the current model.
- Replaced stale staging-era documentation with `https://api.beepbeep.to` as the canonical API endpoint.

## What Worked

The useful simplification was separating three truths:

- Backend truth: identity, devices, membership, readiness, wake target, talk lease.
- PTT session truth: Apple's transmit and audio-session lifecycle.
- Media epoch truth: one talk burst's delivery proof and fallback behavior.

This prevents availability, diagnostics policy, and visible path labels from becoming competing sources of truth.

## What Not To Repeat

- Do not let lane availability imply active delivery.
- Do not route live media through runtime control or WebSocket compatibility paths.
- Do not add concurrent hot-path fanout without proving device pressure, diagnostics pressure, and encryption pressure together.
- Do not keep transitional staging docs as active operational instructions.
- Do not patch visible stuck UI state without also naming the backend, engine, PTT, or media-epoch owner.

## Verification

```bash
cargo test -q -p beepbeep-runtime self_hosted_config_retires_runtime_websocket_by_default
just rust-runtime-test
cargo check -q -p beepbeep-runtime --bin beepbeep-runtime
just engine-test
just swift-test-target runtimeQuicControlCommandUsesPersistentLaneWhenAdvertised
just swift-test-target runtimePersistentControlFailureFallsBackToHTTPWithoutWebSocket
just swift-test-target runtimeTlsPresenceCommandUsesPersistentLaneWhenForced
just swift-test-target forcedUnavailableRuntimeControlPolicySkipsWebSocketCompatibilityAndUsesHTTP
just audio-packet-fuzz
git diff --check
```

`just rust-runtime-test` passed with the existing ignored Postgres integration case:

```text
request_talk_turn_integration_applies_schema_and_enforces_one_current_turn
```

Run that separately through `just runtime-postgres-integration` when Postgres integration is the target.

## Next

1. Deploy runtime config with QUIC/TLS control endpoints, certs, and advertised support enabled.
2. Run the hosted backend/runtime gate against `https://api.beepbeep.to`.
3. Launch a TestFlight/internal build and run the physical matrix: foreground-to-foreground, foreground-to-background, background-to-background, Direct QUIC, Fast Relay QUIC, Fast Relay TLS, Wi-Fi to cellular.
4. Stop on the first matrix failure and convert it into the lowest useful proof: engine, Swift adapter, backend, relay/runtime, or Apple/PTT/audio.
5. After production proves no active client needs it, delete runtime WebSocket compatibility code instead of carrying it forward.

## Files

- [`client/ios/Packages/TurboEngine/Sources/TurboEngine/TurboEngine.swift`](/Users/mau/Development/bb/client/ios/Packages/TurboEngine/Sources/TurboEngine/TurboEngine.swift)
- [`client/ios/Turbo/BackendClient.swift`](/Users/mau/Development/bb/client/ios/Turbo/BackendClient.swift)
- [`client/ios/Turbo/OutboundAudioTransportPlan.swift`](/Users/mau/Development/bb/client/ios/Turbo/OutboundAudioTransportPlan.swift)
- [`client/ios/Turbo/PTTViewModel+TransmitAudioSend.swift`](/Users/mau/Development/bb/client/ios/Turbo/PTTViewModel+TransmitAudioSend.swift)
- [`backend/runtime/src/control_protocol.rs`](/Users/mau/Development/bb/backend/runtime/src/control_protocol.rs)
- [`backend/runtime/src/control_stream.rs`](/Users/mau/Development/bb/backend/runtime/src/control_stream.rs)
- [`backend/runtime/src/runtime_quic.rs`](/Users/mau/Development/bb/backend/runtime/src/runtime_quic.rs)
- [`backend/runtime/src/runtime_tls.rs`](/Users/mau/Development/bb/backend/runtime/src/runtime_tls.rs)
- [`backend/runtime/src/bin/beepbeep-runtime.rs`](/Users/mau/Development/bb/backend/runtime/src/bin/beepbeep-runtime.rs)
- [`backend/relay/src/transport_quic.rs`](/Users/mau/Development/bb/backend/relay/src/transport_quic.rs)
- [`docs/client/DIRECT_QUIC_TRANSPORT.md`](/Users/mau/Development/bb/docs/client/DIRECT_QUIC_TRANSPORT.md)
- [`docs/backend/BACKEND.md`](/Users/mau/Development/bb/docs/backend/BACKEND.md)
- [`docs/reliability/RELIABILITY_PLAN.md`](/Users/mau/Development/bb/docs/reliability/RELIABILITY_PLAN.md)
- [`shared/invariants/registry.json`](/Users/mau/Development/bb/shared/invariants/registry.json)
- [`shared/contracts/app_contract_manifest.json`](/Users/mau/Development/bb/shared/contracts/app_contract_manifest.json)
