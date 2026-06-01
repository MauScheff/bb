# Direct QUIC Transport Plan

Status: Direct QUIC plan/reference.
Scope: transport decision, states, signaling, promotion/demotion, rollout, verification.
Related docs: [`CERTIFICATE-LIFECYCLE.md`](/Users/mau/Development/bb/docs/client/CERTIFICATE-LIFECYCLE.md) owns Direct QUIC device identity and certificate lifecycle.

## Decision

Relay remains the guaranteed path. Direct QUIC over `Network.framework` is an opportunistic upgrade.

- start on relay
- probe direct QUIC in parallel when eligible
- switch to direct only after verification
- fall back immediately to relay on establishment or continuity failure

No HTTP/3 media: the direct path is a custom app protocol over QUIC, not request/response traffic or device-hosted HTTP/3. Apple PushToTalk guidance points toward `Network.framework` + QUIC for secure setup latency, but NAT traversal and fallback remain required.

## Goals

- improve first-audio latency when UDP connectivity is available
- preserve current behavior on hostile/degraded networks
- keep backend as control plane and signaling authority, not media plane
- make direct-path behavior observable and easy to disable

Non-goals: same-LAN-only mode, device-discovery UI, Unison media relay, transmit waiting on direct connectivity, or assuming direct QUIC works on all networks.

## Transport State

Transport path state is separate from session truth:

```swift
enum MediaTransportPathState: Equatable {
    case relay
    case promoting(DirectPromotionContext)
    case direct(DirectConnectionInfo)
    case recovering(RecoveryContext)
}
```

| State | Semantics |
| --- | --- |
| `relay` | Relay is active; direct probing inactive. |
| `promoting` | Relay remains active while candidate exchange, checks, and handshake run. |
| `direct` | Media flows over Direct QUIC; relay remains standby fallback. |
| `recovering` | Direct failed/degraded; app reasserts relay and may schedule retry. |

Do not infer transport state from booleans. Store timestamps and typed reason fields.

## UI Chip

Allowed labels: `Relay`, `Promoting`, `Direct`, `Recovering`.

Rules:

- show `Direct` only after nomination succeeds and media has moved to direct path
- while probing, show `Promoting`, not `Direct`
- on mid-session direct drop, flip to `Recovering`, then `Relay` once relay is confirmed
- chip describes network path only; it is not an encryption claim

## Capability Controls

Backend config extends `TurboBackendRuntimeConfig`:

```swift
struct TurboBackendRuntimeConfig: Decodable {
    let mode: String
    let supportsWebSocket: Bool
    let telemetryEnabled: Bool?
    let supportsDirectQuicUpgrade: Bool
    let directQuicPolicy: TurboDirectQuicPolicy?
}
```

`supportsDirectQuicUpgrade` is the backend kill switch. `directQuicPolicy` should later include `stunServers`, `turnServers`, `promotionTimeoutMs`, `retryBackoffMs`, and `idleDirectUpgradeDisabled`. Production default is `supportsDirectQuicUpgrade = false` until ready.

Local override: `TurboDebugForceRelayOnly`, sourced from `UserDefaults`, launch argument/debug menu, or scenario-runtime override.

Effective decision:

```swift
effectiveDirectUpgradeEnabled =
    runtimeConfig.supportsDirectQuicUpgrade
    && !localDebugForceRelayOnly
```

When forced relay-only: never enter `promoting`, never emit direct-path signaling, keep chip on `Relay`, and log `transport.direct.disabled_local_override`.

## Candidate Model

Assume UDP NAT traversal. Use an ICE-like candidate model:

- host
- server-reflexive from STUN
- relay later via TURN

```swift
struct TurboTransportCandidate: Codable, Equatable {
    let foundation: String
    let component: String
    let transport: String
    let priority: Int
    let kind: CandidateKind
    let address: String
    let port: Int
    let relatedAddress: String?
    let relatedPort: Int?
}

enum CandidateKind: String, Codable {
    case host
    case serverReflexive = "srflx"
    case relay
}
```

For v1 Direct QUIC, `transport` is always `udp`.

## Signaling

Reuse backend websocket signaling. Backend authorizes/routes signals and treats payloads as opaque transport data.

| Signal | Payload |
| --- | --- |
| `offer` | `protocol = "quic-direct-v1"`, `attemptId`, `channelId`, `fromDeviceId`, `toDeviceId`, `quicAlpn`, `certificateFingerprint`, initial candidates, optional role intent |
| `answer` | `protocol = "quic-direct-v1"`, `attemptId`, accepted/rejected, receiver certificate fingerprint, receiver initial candidates |
| `ice-candidate` | `attemptId`, incremental candidate, optional end-of-candidates marker |
| `hangup` | `attemptId`, reason |

Deterministic roles per attempt:

- current transmitter-initiating side becomes initial direct dialer
- receiver listens and dials simultaneously when attempt policy needs symmetric punching
- promotion coordinator owns role assignment; role confusion must not leak to call sites

## Promotion Flow

Session-ready path:

1. Session becomes media-eligible.
2. Active transport is relay.
3. If `effectiveDirectUpgradeEnabled`, enter `promoting`.
4. Gather host and STUN-derived candidates.
5. Exchange `offer`, `answer`, and `ice-candidate`.
6. Start QUIC listener/outbound attempts.
7. Run short direct-path checks.
8. If Direct QUIC is ready and authenticated, mark attempt nominated.
9. Switch active media path from relay to direct.
10. Move state to `direct`.

Wake/background receive path: restore audio on the working path first; probe direct only after receive path is stable. Wake-critical receive must not depend on direct promotion.

Promotion to `direct` requires all of:

- QUIC handshake succeeded
- peer identity matches expected device/fingerprint
- at least one nominated candidate pair passed checks
- direct media path sent and received proof traffic
- cutover does not interrupt active PTT audio-session ownership

Until then, relay remains active.

## Recovery

Demote aggressively on:

- QUIC handshake failure
- connectivity-check timeout
- sustained packet loss or app-level no-progress timeout
- audio path stalls
- peer disconnect/hangup
- app background transitions that invalidate direct socket

Recovery:

1. mark `recovering`
2. reassert relay as send/receive path
3. preserve user-visible media continuity when possible
4. record demotion reason
5. apply retry backoff before later promotion

Never leave session with both direct and relay unavailable because demotion waited too long.

## Security

Direct QUIC requires explicit peer authentication:

- exchange per-attempt certificate fingerprint through signaling
- verify remote fingerprint before promotion

The transport chip is not an E2EE claim. Document any encryption claim separately.

## Implementation Shape

App additions:

- `DirectQuicPromotionCoordinator`
- `DirectQuicSession`
- `MediaTransportPathState`
- transport diagnostics events

Keep `MediaSession` as media boundary and relay as baseline.

Live audio payloads:

- Direct QUIC packet media carries opaque encrypted payload strings produced by `MediaSession`; the backend payload shape does not change.
- Current Opus support is capability-gated by `VoiceMediaCapabilities` and uses `turbo-audio-frame-v2` envelopes for 48 kHz mono 20 ms frames.
- Direct QUIC should send one Opus v2 frame per packet-media datagram and should not batch voice frames on the sender side.
- If peer capability evidence is missing, stale, or unsupported, Direct QUIC sends legacy PCM payloads through the same media boundary.
- Receiver-side playout uses the Direct QUIC low-latency cushion profile: 4 Opus frames initially, with bounded adaptive growth after underruns.
- Fast Relay fallback is packet-first: QUIC control-stream join must be followed by QUIC datagram media join. If datagram join fails, audio uses explicit Fast Relay TCP/TLS (`media-relay-tcp`) or backend websocket fallback; QUIC stream audio must not masquerade as packet media.

Likely factory evolution:

```swift
func makeDefaultMediaSession(
    supportsWebSocket: Bool,
    directUpgradeEnabled: Bool,
    sendAudioChunk: ...,
    reportEvent: ...
) -> any MediaSession
```

Backend ownership remains limited to `/v1/config` capability advertisement, future STUN/TURN policy distribution, routing `offer`/`answer`/`ice-candidate`/`hangup`, and signaling diagnostics. Do not terminate QUIC in backend.

## Diagnostics

Events:

- `transport.path.relay_active`
- `transport.path.promoting`
- `transport.path.direct_active`
- `transport.path.recovering`
- `transport.direct.disabled_local_override`
- `transport.direct.offer_sent`
- `transport.direct.answer_received`
- `transport.direct.candidate_sent`
- `transport.direct.candidate_received`
- `transport.direct.nomination_succeeded`
- `transport.direct.nomination_failed`
- `transport.direct.demoted`

Fields: `channelId`, `contactId`, `attemptId`, `localDeviceId`, `peerDeviceId`, `activePath`, `reason`.

## Rollout

| Phase | Scope |
| --- | --- |
| 0 | document decision; add runtime config fields; add local force-relay override; add transport-path state and UI chip |
| 1 | implement QUIC listener/connector spike on physical devices; add media cutover after proven path; verify signaling, auth, and handshake timing |
| 2 | add STUN candidate gathering and server-reflexive advertisement; reuse local UDP port when applicable; trickle answer-side candidates and end-of-candidates; let listener consume remote answer candidates; keep answerer attempts alive after initial outbound failure; re-trickle offerer candidates after accepted answer; keep wake/background relay-first |
| 3 | record nominated path before `promoting -> direct`; add direct-path consent pings, demotion, retry backoff, richer diagnostics, classified retry metadata, scenario/device proof loops |
| 4 | add TURN relay candidates if direct UDP success rate is unacceptable |

## Verification

Automated:

- reducer tests for transport-path transitions
- coordinator tests for promotion/demotion
- signaling codec tests for `offer`, `answer`, `ice-candidate`
- debug-override tests proving `TurboDebugForceRelayOnly` blocks promotion

Physical devices:

- same Wi-Fi
- different Wi-Fi networks
- Wi-Fi to cellular
- background receiver wake then relay recovery
- direct-path failure mid-session with immediate relay demotion

Simulator proves state-machine and signaling logic, not real QUIC transport behavior.

## Next Change

Implement the first real ICE-like layer:

1. prove offerer-listener / answerer-dialer hole punching on physical devices across NATs
2. capture common real-network failures and tune classified retry/diagnostics policy

Keep relay-first behavior intact while moving from QUIC spike to narrow, testable direct-path layer.
