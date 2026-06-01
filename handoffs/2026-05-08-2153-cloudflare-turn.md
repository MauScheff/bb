# Handoff 2026-05-08 21:53

## Summary

Cloudflare TURN credentialing is staged in the backend and exposed through runtime config, but live production remains TURN-disabled because Cloudflare TURN secrets are not present in the deployed environment. The important architectural finding is that Cloudflare ICE/TURN credentials are not enough by themselves for the current Direct QUIC media path, because the app uses Network.framework QUIC rather than a WebRTC ICE transport.

## Current truth

- `https://beepbeep.to/v1/config?probe=turn-20260508` advertises Direct QUIC with Cloudflare STUN first, Google STUN fallback, `turnEnabled=false`, `turnProvider=cloudflare`, `turnPolicyPath=/v1/direct-quic/ice-servers`, and `turnCredentialTtlSeconds=3600`.
- `POST https://beepbeep.to/v1/direct-quic/ice-servers` is live and currently returns `{"error":"missing Cloudflare TURN config"}` because secrets are absent.
- `https://mauscheff.unison-services.cloud/h/rci6klx6easxtoe4xs7vpiabcz2j6rjvh442zdroykw7wx5royeq/v1/dev/deploy-stamp` shows `hasCloudflareTurnKeyId=false`, `hasCloudflareTurnApiToken=false`, and `cloudflareTurnEnabled=false`.
- A cache-busting query param may be needed when checking `/v1/dev/deploy-stamp` through `beepbeep.to`; the custom domain briefly served a cached old GET response after deploy.
- The Direct QUIC provisioning probe passed against production after deploy.

## What changed this session

- Added backend Cloudflare TURN config and credential-generation route:
  - `TURBO_CLOUDFLARE_TURN_KEY_ID`
  - `TURBO_CLOUDFLARE_TURN_API_TOKEN`
  - `POST /v1/direct-quic/ice-servers`
- Extended `/v1/config` Direct QUIC policy with STUN provider metadata, TURN status, TURN policy path, credential TTL, and experiment bucket.
- Added deploy-stamp fields for Cloudflare TURN secret visibility.
- Added Swift models for TURN policy and Cloudflare ICE server responses.
- Added `TurboBackendClient.directQuicIceServers()` for fetching short-lived ICE server credentials once TURN is enabled.
- Added merged diagnostics fields for Direct QUIC STUN providers, TURN status, TURN provider, TURN path, credential TTL, and experiment bucket.
- Added `scripts/turn_policy_probe.py` and `just turn-policy-probe`.
- Extended `scripts/direct_quic_provisioning_probe.py` to validate TURN policy shape when TURN is enabled.

## What is not working

- Real TURN relay candidates are not active in the media path yet.
- The current Direct QUIC implementation uses Network.framework QUIC sockets. Standard TURN credentials are meant for an ICE/WebRTC-style transport. A TURN allocation relays encapsulated TURN data between the client and TURN server; Network.framework QUIC does not expose a hook to insert that TURN layer under its UDP socket.
- Therefore, enabling Cloudflare TURN credentials alone will not make Direct QUIC use Cloudflare relay candidates. It only makes credentials available for a future transport that can consume them.
- Swift targeted testing compiled the new code, but the test bundle still fails on the known unrelated notification badge clearing regression.

## Recommended next step

1. Decide the transport strategy for real relay candidates:
   - Prefer WebRTC/ICE for the direct media path if we want managed TURN to be a first-class fallback.
   - Keep Network.framework QUIC for host/srflx direct paths and treat WebSocket relay as the relay fallback if we do not want a transport migration now.
2. If testing Cloudflare credential issuance only, create a Cloudflare Realtime TURN key/token, add the two env vars, deploy, and run `just turn-policy-probe "--require-enabled"`.
3. If pursuing TURN media, spike a small WebRTC data/audio transport path or a relay-specific media transport before trying to add `.relay` candidates to the existing Direct QUIC probe controller.

## Commands that matter

```bash
just deploy-force
curl -skS -H 'Cache-Control: no-cache' 'https://beepbeep.to/v1/config?probe=turn-20260508' | jq '{directQuicPolicy}'
curl -skS -H 'Cache-Control: no-cache' -H 'x-turbo-user-handle: @mau' -H 'Authorization: Bearer @mau' 'https://beepbeep.to/v1/dev/deploy-stamp?probe=turn-20260508' | jq
curl -skS -X POST -H 'x-turbo-user-handle: @quinn' -H 'Authorization: Bearer @quinn' https://beepbeep.to/v1/direct-quic/ice-servers | jq
just turn-policy-probe
just turn-policy-probe "--require-enabled"
just direct-quic-provisioning-probe
```

## Files that matter

- [`cloudflare_turn_policy.u`](/Users/mau/Development/Turbo/cloudflare_turn_policy.u)
- [`Turbo/TurboBackendModels.swift`](/Users/mau/Development/Turbo/Turbo/TurboBackendModels.swift)
- [`Turbo/BackendClient.swift`](/Users/mau/Development/Turbo/Turbo/BackendClient.swift)
- [`Turbo/AppDiagnostics.swift`](/Users/mau/Development/Turbo/Turbo/AppDiagnostics.swift)
- [`Turbo/PTTViewModel.swift`](/Users/mau/Development/Turbo/Turbo/PTTViewModel.swift)
- [`scripts/turn_policy_probe.py`](/Users/mau/Development/Turbo/scripts/turn_policy_probe.py)
- [`scripts/direct_quic_provisioning_probe.py`](/Users/mau/Development/Turbo/scripts/direct_quic_provisioning_probe.py)
- [`justfile`](/Users/mau/Development/Turbo/justfile)

## Notes

- Current production behavior remains safe: without Cloudflare TURN secrets, clients stay on Cloudflare/Google STUN plus the existing WebSocket relay fallback.
- Do not simply include `.relay` in `DirectQuicProbeController.viableProbeCandidates`; the candidate would not work without a transport that can keep the TURN allocation alive and decapsulate TURN data for QUIC.
