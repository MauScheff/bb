#!/usr/bin/env python3

from __future__ import annotations

import argparse
import asyncio
import urllib.parse
import uuid

from route_probe import (
    RouteProbeFailure,
    connected_websocket_pair,
    direct_quic_identity_for_device,
    request,
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def participant(handle: str, prefix: str) -> dict[str, str]:
    return {
        "handle": handle,
        "device_id": f"{prefix}-{uuid.uuid4()}",
    }


def peer_identity_fingerprint(payload: dict) -> str | None:
    identity = payload.get("peerDirectQuicIdentity")
    if not isinstance(identity, dict):
        return None
    if identity.get("status") != "active":
        return None
    fingerprint = identity.get("fingerprint")
    return fingerprint if isinstance(fingerprint, str) else None


def require_no_certificate_material(identity: object, label: str) -> None:
    require(isinstance(identity, dict), f"{label} missing Direct QUIC identity: {identity}")
    require(
        "certificateDerBase64" not in identity,
        f"{label} leaked certificate DER material: {identity}",
    )


async def main() -> int:
    parser = argparse.ArgumentParser(description="Verify deployed Direct QUIC provisioning metadata.")
    parser.add_argument("--base-url", default="https://api.beepbeep.to")
    parser.add_argument("--caller", default="@quinn")
    parser.add_argument("--callee", default="@sasha")
    parser.add_argument("--insecure", action="store_true")
    args = parser.parse_args()

    caller = participant(args.caller, "direct-quic-probe-caller")
    callee = participant(args.callee, "direct-quic-probe-callee")

    config = request(args.base_url, "/v1/config", caller["handle"], insecure=args.insecure)
    require(
        config.get("supportsDirectQuicProvisioning") is True,
        f"backend did not advertise Direct QUIC provisioning support: {config}",
    )
    supports_upgrade = config.get("supportsDirectQuicUpgrade")
    require(
        isinstance(supports_upgrade, bool),
        f"backend did not report Direct QUIC upgrade capability as a boolean: {config}",
    )
    direct_quic_policy = config.get("directQuicPolicy")
    require(
        isinstance(direct_quic_policy, dict),
        f"backend did not report Direct QUIC policy as an object: {config}",
    )
    stun_servers = direct_quic_policy.get("stunServers")
    stun_providers = direct_quic_policy.get("stunProviders", [])
    turn_enabled = direct_quic_policy.get("turnEnabled", False)
    if supports_upgrade:
        require(
            isinstance(stun_servers, list) and len(stun_servers) > 0,
            f"backend advertises Direct QUIC upgrade without STUN servers: {config}",
        )
        for index, stun_server in enumerate(stun_servers):
            require(
                isinstance(stun_server, dict)
                and isinstance(stun_server.get("host"), str)
                and stun_server.get("host"),
                f"Direct QUIC STUN server {index} is missing a host: {config}",
            )
            port = stun_server.get("port", 3478)
            require(
                isinstance(port, int) and 0 < port <= 65535,
                f"Direct QUIC STUN server {index} has an invalid port: {config}",
            )
        require(
            isinstance(stun_providers, list),
            f"backend Direct QUIC STUN providers must be a list when present: {config}",
        )
        for provider_index, provider in enumerate(stun_providers):
            require(
                isinstance(provider, dict)
                and isinstance(provider.get("name"), str)
                and provider.get("name"),
                f"Direct QUIC STUN provider {provider_index} is missing a name: {config}",
            )
            provider_servers = provider.get("servers")
            require(
                isinstance(provider_servers, list) and len(provider_servers) > 0,
                f"Direct QUIC STUN provider {provider_index} has no servers: {config}",
            )
        require(
            isinstance(turn_enabled, bool),
            f"Direct QUIC TURN enabled flag must be a boolean when present: {config}",
        )
        if turn_enabled:
            require(
                direct_quic_policy.get("turnProvider") == "cloudflare",
                f"enabled Direct QUIC TURN must name the Cloudflare provider: {config}",
            )
            require(
                direct_quic_policy.get("turnPolicyPath") == "/v1/direct-quic/ice-servers",
                f"enabled Direct QUIC TURN must expose the ICE server policy path: {config}",
            )
            ttl = direct_quic_policy.get("turnCredentialTtlSeconds")
            require(
                isinstance(ttl, int) and ttl > 0,
                f"enabled Direct QUIC TURN must expose a positive credential TTL: {config}",
            )

    request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure)
    request(args.base_url, "/v1/dev/reset-state", caller["handle"], method="POST", insecure=args.insecure)
    request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure)

    try:
        request(
            args.base_url,
            "/v1/devices/register",
            caller["handle"],
            method="POST",
            body={
                "deviceId": f"invalid-direct-quic-{uuid.uuid4()}",
                "deviceLabel": "invalid-direct-quic",
                "directQuicIdentity": {"fingerprint": "sha256:bad"},
            },
            insecure=args.insecure,
        )
        raise RuntimeError("invalid Direct QUIC fingerprint registration unexpectedly succeeded")
    except RouteProbeFailure:
        pass

    for current in (caller, callee):
        session = request(args.base_url, "/v1/auth/session", current["handle"], method="POST", insecure=args.insecure)
        current["user_id"] = session["userId"]
        current["identity"] = direct_quic_identity_for_device(current["device_id"])
        registered = request(
            args.base_url,
            "/v1/devices/register",
            current["handle"],
            method="POST",
            body={
                "deviceId": current["device_id"],
                "deviceLabel": current["device_id"],
                "directQuicIdentity": current["identity"],
            },
            insecure=args.insecure,
        )
        require(
            registered.get("directQuicIdentity", {}).get("fingerprint") == current["identity"]["fingerprint"],
            f"registration did not round-trip Direct QUIC identity for {current['handle']}: {registered}",
        )
        require_no_certificate_material(
            registered.get("directQuicIdentity"),
            f"registration:{current['handle']}",
        )

    rotated_caller_identity = direct_quic_identity_for_device(f"{caller['device_id']}:rotated")
    rotated = request(
        args.base_url,
        "/v1/devices/register",
        caller["handle"],
        method="POST",
        body={
            "deviceId": caller["device_id"],
            "deviceLabel": caller["device_id"],
            "directQuicIdentity": {
                **rotated_caller_identity,
                "certificateDerBase64": "AQID",
            },
        },
        insecure=args.insecure,
    )
    require(
        rotated.get("directQuicIdentity", {}).get("fingerprint") == rotated_caller_identity["fingerprint"],
        f"rotated registration did not replace Direct QUIC fingerprint: {rotated}",
    )
    require_no_certificate_material(rotated.get("directQuicIdentity"), "registration:rotated-caller")
    caller["identity"] = rotated_caller_identity

    preserved = request(
        args.base_url,
        "/v1/devices/register",
        caller["handle"],
        method="POST",
        body={
            "deviceId": caller["device_id"],
            "deviceLabel": caller["device_id"],
        },
        insecure=args.insecure,
    )
    require(
        preserved.get("directQuicIdentity", {}).get("fingerprint") == caller["identity"]["fingerprint"],
        f"registration without identity did not preserve Direct QUIC metadata: {preserved}",
    )
    require_no_certificate_material(preserved.get("directQuicIdentity"), "registration:preserved-caller")

    beep = request(
        args.base_url,
        "/v1/beeps",
        caller["handle"],
        method="POST",
        body={"friendHandle": callee["handle"]},
        insecure=args.insecure,
    )
    accepted = request(
        args.base_url,
        f"/v1/beeps/{beep['beepId']}/accept",
        callee["handle"],
        method="POST",
        insecure=args.insecure,
    )
    channel_id = accepted["channelId"]

    async with connected_websocket_pair(args.base_url, caller, callee, args.insecure):
        for current in (caller, callee):
            request(
                args.base_url,
                f"/v1/channels/{channel_id}/join",
                current["handle"],
                method="POST",
                body={"deviceId": current["device_id"]},
                insecure=args.insecure,
            )

        caller_readiness = request(
            args.base_url,
            f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
            caller["handle"],
            insecure=args.insecure,
        )
        callee_readiness = request(
            args.base_url,
            f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(callee['device_id'])}",
            callee["handle"],
            insecure=args.insecure,
        )

    require(
        peer_identity_fingerprint(caller_readiness) == callee["identity"]["fingerprint"],
        f"caller readiness did not project callee Direct QUIC identity: {caller_readiness}",
    )
    require_no_certificate_material(
        caller_readiness.get("peerDirectQuicIdentity"),
        "readiness:caller-peer",
    )
    require(
        peer_identity_fingerprint(callee_readiness) == caller["identity"]["fingerprint"],
        f"callee readiness did not project caller Direct QUIC identity: {callee_readiness}",
    )
    require_no_certificate_material(
        callee_readiness.get("peerDirectQuicIdentity"),
        "readiness:callee-peer",
    )

    print(
        "DIRECT QUIC PROVISIONING PROBE PASSED: "
        f"{caller['device_id']} <-> {callee['device_id']} against {args.base_url}"
        f" supportsDirectQuicUpgrade={supports_upgrade}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
