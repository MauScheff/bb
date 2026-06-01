# Turbo Media Relay

Canary relay for Turbo audio and peer hint frames.

Scope:

- Unison remains the control plane.
- The relay validates a shared canary token, joins two device IDs into a session, and forwards encrypted audio plus non-authoritative peer hint frames.
- Preferred live audio is QUIC datagram packet media (`packet-audio`) over UDP `443`.
- Degraded Fast Relay fallback is explicit TCP/TLS ordered media (`tcp-audio`) over TCP `443`.
- QUIC stream audio is unsupported. Control may use ordered streams; packet media must not silently degrade into QUIC stream media.

## Runtime Config

Required:

```bash
export TURBO_RELAY_CERT_PEM=/etc/letsencrypt/live/relay.beepbeep.to/fullchain.pem
export TURBO_RELAY_KEY_PEM=/etc/letsencrypt/live/relay.beepbeep.to/privkey.pem
export TURBO_RELAY_SHARED_TOKEN=''
```

Optional:

```bash
export TURBO_RELAY_QUIC_ADDR=0.0.0.0:443
export TURBO_RELAY_TCP_ADDR=0.0.0.0:443
export TURBO_RELAY_SESSION_TTL_SECONDS=180
```

## Build

```bash
cargo build --release --bin relay
cargo build --features quinn-probe --bin probe
```

## Run

```bash
RUST_LOG=info ./target/release/relay
```

The relay binary uses `quiche` for the UDP/QUIC server. The optional `probe`
binary remains a small Quinn client compatibility probe.

## Canary Proof

After deploying, verify all three relay surfaces:

```bash
relay/target/debug/probe both relay.beepbeep.to 443
relay/target/debug/probe datagram-pair relay.beepbeep.to 443
swift tools/scripts/probe_media_relay_network_framework.swift relay.beepbeep.to 443
printf '%s\n' '{"type":"join","session_id":"tcp-probe-session","device_id":"tcp-probe-device-a","peer_device_id":"tcp-probe-device-b","token":""}' \
  | timeout 6 openssl s_client -connect relay.beepbeep.to:443 -servername relay.beepbeep.to -quiet 2>/tmp/turbo-relay-openssl.err \
  | head -n 1
```

Expected results: QUIC stream `join-ack`, QUIC datagram `datagram-join-ack`,
datagram `packet-audio` forwarding, Network.framework datagram join, and TCP/TLS
`join-ack`.

## DNS / GCP

For the first production canary:

1. Create one small GCP VM with a static external IP.
2. Open UDP `443` and TCP `443`.
3. Keep DNS in Cloudflare and add `relay.beepbeep.to` pointing to the GCP static IP.
4. Leave that DNS record DNS-only for now. Do not proxy it through normal Cloudflare HTTP proxying; QUIC/UDP needs direct reachability unless we later add Spectrum.
5. Put a public TLS certificate for `relay.beepbeep.to` on the VM.
6. Let the `turbo-relay` binary bind privileged port `443` directly, or grant the service equivalent `CAP_NET_BIND_SERVICE` permissions.

Canonical GCP project:

```bash
export TURBO_RELAY_GCP_PROJECT=beep-beep-495919
```

Current canary deployment:

```text
project: beep-beep-495919
region: europe-west6
zone: europe-west6-a
vm: turbo-relay-1
static ip: 34.65.146.215
dns: relay.beepbeep.to -> 34.65.146.215, DNS-only in Cloudflare
quic: udp/443
tcp/tls: tcp/443
systemd service: turbo-relay
env file on VM: /etc/turbo-relay/env
```

Use the env var in setup commands instead of relying on the active `gcloud`
project:

```bash
gcloud config set project "$TURBO_RELAY_GCP_PROJECT"
gcloud compute instances list --project "$TURBO_RELAY_GCP_PROJECT"
```

## iOS Canary Config

The app reads:

```bash
TURBO_DEBUG_MEDIA_RELAY_ENABLED=true
TURBO_DEBUG_FORCE_MEDIA_RELAY=false
TURBO_MEDIA_RELAY_HOST=relay.beepbeep.to
TURBO_MEDIA_RELAY_QUIC_PORT=443
TURBO_MEDIA_RELAY_TCP_PORT=443
TURBO_MEDIA_RELAY_TOKEN=''
```

The diagnostics pane also exposes:

- `Enable media relay`
- `Force media relay`
- relay configured/active state
- relay host and ports

For the first canary, the relay token is intentionally empty so physical-device testing only needs diagnostics toggles. Use `Force media relay` only when explicitly testing the packet relay path. Normal canary mode leaves Direct QUIC P2P first and uses Fast Relay as fallback.
