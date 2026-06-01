#!/usr/bin/env python3

from __future__ import annotations

import argparse

from route_probe import RouteProbeFailure, request


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify deployed Cloudflare TURN policy wiring.")
    parser.add_argument("--base-url", default="https://staging.beepbeep.to")
    parser.add_argument("--handle", default="@quinn")
    parser.add_argument("--insecure", action="store_true")
    parser.add_argument(
        "--require-enabled",
        action="store_true",
        help="Fail if /v1/config reports TURN disabled.",
    )
    args = parser.parse_args()

    config = request(args.base_url, "/v1/config", args.handle, insecure=args.insecure)
    direct_quic_policy = config.get("directQuicPolicy")
    require(isinstance(direct_quic_policy, dict), f"missing Direct QUIC policy: {config}")

    turn_enabled = direct_quic_policy.get("turnEnabled")
    require(isinstance(turn_enabled, bool), f"turnEnabled must be a boolean: {config}")
    if args.require_enabled:
        require(turn_enabled is True, f"TURN is not enabled in runtime config: {config}")

    if not turn_enabled:
        print("TURN POLICY PROBE PASSED: TURN disabled because backend config is absent")
        return 0

    policy_path = direct_quic_policy.get("turnPolicyPath")
    require(policy_path == "/v1/direct-quic/ice-servers", f"unexpected TURN policy path: {config}")
    ttl = direct_quic_policy.get("turnCredentialTtlSeconds")
    require(isinstance(ttl, int) and ttl > 0, f"invalid TURN credential TTL: {config}")

    try:
        ice_policy = request(args.base_url, policy_path, args.handle, method="POST", insecure=args.insecure)
    except RouteProbeFailure as exc:
        raise RuntimeError(f"TURN policy route failed while enabled: {exc}") from exc

    ice_servers = ice_policy.get("iceServers")
    require(isinstance(ice_servers, list) and ice_servers, f"missing iceServers: {ice_policy}")

    stun_urls: list[str] = []
    turn_urls: list[str] = []
    for index, server in enumerate(ice_servers):
        require(isinstance(server, dict), f"iceServers[{index}] is not an object: {ice_policy}")
        urls = server.get("urls")
        if isinstance(urls, str):
            urls = [urls]
        require(isinstance(urls, list) and urls, f"iceServers[{index}] has no urls: {ice_policy}")
        for url in urls:
            require(isinstance(url, str) and url, f"iceServers[{index}] has invalid url: {ice_policy}")
            if url.startswith("stun:"):
                stun_urls.append(url)
            if url.startswith("turn:") or url.startswith("turns:"):
                turn_urls.append(url)
        if any(str(url).startswith(("turn:", "turns:")) for url in urls):
            require(isinstance(server.get("username"), str) and server["username"], f"TURN server lacks username: {server}")
            require(
                isinstance(server.get("credential"), str) and server["credential"],
                f"TURN server lacks credential: {server}",
            )

    require(stun_urls, f"Cloudflare response did not include STUN URLs: {ice_policy}")
    require(turn_urls, f"Cloudflare response did not include TURN URLs: {ice_policy}")
    print(
        "TURN POLICY PROBE PASSED: "
        f"{len(stun_urls)} STUN urls, {len(turn_urls)} TURN urls, ttl={ttl}s"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
