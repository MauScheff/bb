# Handoff 2026-05-08 22:23

## Summary

We decided the next connection-quality phase should be a purpose-built Turbo media relay, not WebRTC and not a TURN-first implementation. Direct QUIC remains the best path when peer-to-peer works. The new relay should sit between Direct QUIC and the existing Unison/WebSocket relay: UDP when possible, TCP/TLS when UDP is blocked, and WebSocket as the last fallback.

## Current truth

- Direct QUIC already works when the network allows peer-to-peer connectivity.
- The current fallback is Unison/WebSocket relay. It is reliable enough to keep, but it is not ideal as the best media fallback because it runs real-time audio through the control-plane/backend path.
- Cloudflare STUN is now represented in the backend Direct QUIC policy before Google STUN, with Google STUN still present as fallback.
- Cloudflare TURN credential generation is staged in the backend, but production still has `turnEnabled=false` because Cloudflare TURN secrets are not configured.
- Cloudflare TURN credentials alone do not make the current Network.framework QUIC media path use TURN relay media.

## What changed this session

- Architecture direction moved from "enable Cloudflare TURN media" to "build our own custom media relay."
- The relay is intentionally decoupled and optional, so it can be A/B tested and removed without breaking existing Direct QUIC or WebSocket fallback.
- Hosting is deferred. A single-region Rust relay is useful before any global edge work.
- Cloudflare Spectrum or another global accelerator can come later if the single-region relay proves better than WebSocket fallback.

## Target Transport Ladder

```text
1. Direct QUIC peer-to-peer
2. Turbo media relay: UDP <-> UDP
3. Turbo media relay: UDP <-> TCP/TLS or TCP/TLS <-> UDP
4. Turbo media relay: TCP/TLS <-> TCP/TLS
5. Existing Unison/WebSocket relay
```

The relay should allow each peer to choose its own working transport. One device can use UDP while the other uses TCP/TLS. The relay forwards authenticated encrypted media packets by session and peer identity, not by blindly piping socket bytes.

## Why Custom Relay Instead Of TURN

- TURN is a generic relay protocol. Turbo needs a narrow media relay for encrypted audio frames, sessions, device IDs, diagnostics, and fallback state.
- A custom relay avoids implementing full TURN allocation, permission, channel-bind, refresh, and generic relay semantics.
- The relay can report product-level diagnostics: selected transport, packet loss, packet age, late drops, reconnects, peer presence at relay, session expiry, and fallback reason.
- The relay can be formally modeled as a small state machine before runtime IO is added.
- A custom TCP/TLS relay may still beat the current WebSocket relay by avoiding Unison/control-plane routing and using audio-specific framing/backpressure, though this needs measurement.

## Rust Relay Shape

```text
relay/
  Cargo.toml
  src/
    protocol.rs      pure packet/session wire types
    state.rs         pure relay state machine
    auth.rs          backend-issued token validation
    udp.rs           UDP listener
    tcp.rs           TCP/TLS listener
    metrics.rs       counters, histograms, session stats
    main.rs          tokio runtime and config
```

Core packet envelope:

```text
sessionId
senderDeviceId
sequenceNumber
sentAt
payloadCiphertext
```

Core state-machine cases:

- session created
- peer joined over UDP
- peer joined over TCP/TLS
- peer switched transport
- packet forwarded
- packet dropped unauthenticated
- packet dropped because peer missing
- packet dropped because queue full or too late
- peer timed out
- session expired

## Backend Shape

Add a control-plane route:

```text
POST /v1/media-relay/session
```

Response shape:

```json
{
  "sessionId": "...",
  "token": "...",
  "expiresAt": "...",
  "region": "single",
  "udp": { "host": "relay.beepbeep.to", "port": 443 },
  "tcp": { "host": "relay.beepbeep.to", "port": 443 }
}
```

The backend stays authoritative for session issuance and identity. The relay validates short-lived tokens but does not own contacts, invites, channels, or durable app state.

## iOS Shape

Add a media relay transport alongside existing direct and WebSocket paths:

```text
direct-quic
media-relay
websocket-relay
```

Candidate behavior:

- keep trying Direct QUIC first
- request relay session when direct probe fails or is slow
- try UDP relay first
- try TCP/TLS relay if UDP cannot establish or stalls
- fall back to WebSocket relay if custom relay fails
- continue to record selected transport in diagnostics and connection badge

## Formal / Property Testing

The pure relay state machine should be tested before IO:

- packets only forward within the same relay session
- unauthenticated packets never forward
- expired sessions never forward
- duplicate joins converge to one active peer state
- peer can switch UDP/TCP without creating duplicate active peers
- UDP-to-TCP and TCP-to-UDP forwarding works
- queue pressure drops media instead of blocking unrelated sessions
- stale peers and sessions expire deterministically

If using `anodized` or a similar Rust modeling/property package, start with `state.rs` and keep runtime sockets outside the model.

## Hosting Plan

Phase 1:

- run locally
- then deploy one small public Rust relay instance
- measure against current WebSocket relay

Phase 2:

- deploy 2-3 regional relays
- backend picks region by simple config or latency hints

Phase 3:

- consider Cloudflare Spectrum in front of relay origins for global TCP/UDP ingress
- consider other global acceleration only if Spectrum is unavailable or uneconomical

Do not block Phase 1 on global edge. The first proof is whether the custom UDP/TCP relay beats the current Unison/WebSocket fallback.

## STUN Decision

- Prefer Cloudflare STUN first because Turbo already depends on Cloudflare infrastructure and Cloudflare publishes `stun.cloudflare.com:3478/udp`.
- Keep Google STUN as a backup provider because STUN is cheap, stateless, and provider fallback is low risk.
- Do not configure Cloudflare TURN secrets unless we specifically want to test credential issuance; TURN media is not the current implementation path.

## Recommended Next Step

1. Write `DIRECT_MEDIA_RELAY_PLAN.md` from this handoff if we want a persistent design doc.
2. Scaffold `relay/` as a Rust workspace with pure `protocol.rs` and `state.rs`.
3. Add property tests for the relay state machine.
4. Add a minimal UDP local loop test.
5. Add backend route shape for relay session issuance.
6. Add iOS relay client behind a runtime flag.
7. Measure custom TCP/TLS relay and UDP relay against current WebSocket relay before choosing global hosting.

## Commands that matter

```bash
just turn-policy-probe
just direct-quic-provisioning-probe
curl -skS 'https://beepbeep.to/v1/config?probe=relay-plan' | jq '{directQuicPolicy}'
```

## Files that matter

- [`handoffs/2026-05-08-2153-cloudflare-turn.md`](/Users/mau/Development/Turbo/handoffs/2026-05-08-2153-cloudflare-turn.md)
- [`Turbo/DirectQuicProbeController.swift`](/Users/mau/Development/Turbo/Turbo/DirectQuicProbeController.swift)
- [`Turbo/PTTViewModel+DirectQuic.swift`](/Users/mau/Development/Turbo/Turbo/PTTViewModel+DirectQuic.swift)
- [`Turbo/PTTViewModel+Transmit.swift`](/Users/mau/Development/Turbo/Turbo/PTTViewModel+Transmit.swift)
- [`Turbo/TurboBackendModels.swift`](/Users/mau/Development/Turbo/Turbo/TurboBackendModels.swift)
- [`cloudflare_turn_policy.u`](/Users/mau/Development/Turbo/cloudflare_turn_policy.u)

## Notes

- The current Cloudflare TURN backend surface can stay. It is harmless while disabled and may be useful for experiments.
- The custom relay must not replace Direct QUIC. It only improves the fallback path.
- The custom relay must not replace WebSocket fallback on day one. WebSocket remains the safety net.
