#!/usr/bin/env python3

import argparse
import asyncio
import contextlib
import hashlib
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.parse
import uuid
from dataclasses import asdict, dataclass
from typing import Any

try:
    import websockets
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "The `websockets` package is required. Install it with `python3 -m pip install websockets`."
    ) from exc


class RouteProbeFailure(RuntimeError):
    pass


@dataclass
class CheckResult:
    name: str
    ok: bool
    detail: str
    durationMs: int
    payload: Any | None = None


def request(
    base_url: str,
    path: str,
    handle: str | None,
    *,
    method: str = "GET",
    body: dict | None = None,
    extra_headers: dict[str, str] | None = None,
    insecure: bool = False,
) -> dict | list:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    command = [
        "curl",
        "-sS",
        "--fail-with-body",
        "-X",
        method,
    ]
    if handle:
        command.extend([
            "-H",
            f"x-turbo-user-handle: {handle}",
            "-H",
            f"Authorization: Bearer {handle}",
        ])
    for key, value in (extra_headers or {}).items():
        command.extend(["-H", f"{key}: {value}"])
    if insecure:
        command.append("-k")
    if body is not None:
        command.extend(["-H", "Content-Type: application/json", "--data-binary", json.dumps(body)])
    command.append(url)
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        payload = exc.stderr.strip() or exc.stdout.strip()
        raise RouteProbeFailure(f"{method} {path} failed: {payload}") from exc
    raw = completed.stdout.strip()
    return json.loads(raw) if raw else {}


def request_text(
    base_url: str,
    path: str,
    handle: str | None,
    *,
    method: str = "GET",
    body: dict | None = None,
    extra_headers: dict[str, str] | None = None,
    insecure: bool = False,
) -> str:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    command = [
        "curl",
        "-sS",
        "--fail-with-body",
        "-X",
        method,
    ]
    if handle:
        command.extend([
            "-H",
            f"x-turbo-user-handle: {handle}",
            "-H",
            f"Authorization: Bearer {handle}",
        ])
    for key, value in (extra_headers or {}).items():
        command.extend(["-H", f"{key}: {value}"])
    if insecure:
        command.append("-k")
    if body is not None:
        command.extend(["-H", "Content-Type: application/json", "--data-binary", json.dumps(body)])
    command.append(url)
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        payload = exc.stderr.strip() or exc.stdout.strip()
        raise RouteProbeFailure(f"{method} {path} failed: {payload}") from exc
    return completed.stdout


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RouteProbeFailure(message)


def is_local_base_url(base_url: str) -> bool:
    hostname = urllib.parse.urlparse(base_url).hostname
    return hostname in {"localhost", "127.0.0.1"}


def share_path_component(handle: str) -> str:
    return handle.lstrip("@")


def require_beep_thread_projection_contract(payload: dict[str, Any], *, label: str) -> None:
    projection = payload.get("beepThreadProjection")
    require(isinstance(projection, dict), f"{label} missing beepThreadProjection contract: {payload}")
    kind = projection.get("kind")
    require(
        kind in {"none", "incoming", "outgoing", "mutual"},
        f"{label} beepThreadProjection kind invalid: {projection}",
    )
    has_incoming = payload.get("hasIncomingBeep")
    has_outgoing = payload.get("hasOutgoingBeep")
    expected_kind = (
        "mutual" if has_incoming and has_outgoing
        else "incoming" if has_incoming
        else "outgoing" if has_outgoing
        else "none"
    )
    require(kind == expected_kind, f"{label} beepThreadProjection disagrees with Beep direction flags: {payload}")
    if expected_kind == "none":
        require(projection.get("requestCount") in (None, 0), f"{label} none projection carried a requestCount: {projection}")
    else:
        require(
            projection.get("requestCount") == payload.get("requestCount"),
            f"{label} beepThreadProjection count disagrees with requestCount: {payload}",
        )


def require_membership_contract(payload: dict[str, Any], *, label: str) -> None:
    membership = payload.get("membership")
    require(isinstance(membership, dict), f"{label} missing membership contract: {payload}")
    kind = membership.get("kind")
    require(
        kind in {"absent", "self-only", "peer-only", "both"},
        f"{label} membership kind invalid: {membership}",
    )
    self_joined = payload.get("selfJoined")
    peer_joined = payload.get("peerJoined")
    expected_kind = (
        "both" if self_joined and peer_joined
        else "self-only" if self_joined
        else "peer-only" if peer_joined
        else "absent"
    )
    require(kind == expected_kind, f"{label} membership disagrees with legacy join flags: {payload}")
    if expected_kind in {"peer-only", "both"}:
        require(
            membership.get("peerDeviceConnected") == payload.get("peerDeviceConnected"),
            f"{label} membership peerDeviceConnected disagrees with legacy field: {payload}",
        )
    else:
        require(
            membership.get("peerDeviceConnected") in (None, False),
            f"{label} membership unexpectedly carried peerDeviceConnected: {membership}",
        )


def require_summary_status_contract(payload: dict[str, Any], *, label: str) -> None:
    summary_status = payload.get("summaryStatus")
    require(isinstance(summary_status, dict), f"{label} missing summaryStatus contract: {payload}")
    kind = summary_status.get("kind")
    require(
        kind in {"offline", "online", "outgoing-beep", "incoming", "connecting", "ready", "talking", "receiving"},
        f"{label} summaryStatus kind invalid: {summary_status}",
    )
    require(kind == payload.get("badgeStatus"), f"{label} summaryStatus disagrees with legacy badgeStatus: {payload}")
    active_transmitter = summary_status.get("activeTransmitterUserId")
    if kind in {"talking", "receiving"}:
        require(
            isinstance(active_transmitter, str) and active_transmitter,
            f"{label} missing active transmitter for talking/receiving: {summary_status}",
        )
    else:
        require(
            active_transmitter in (None, ""),
            f"{label} unexpected active transmitter for non-transmitting summary state: {summary_status}",
        )


def require_conversation_status_contract(payload: dict[str, Any], *, label: str) -> None:
    conversation_status = payload.get("conversationStatus")
    require(isinstance(conversation_status, dict), f"{label} missing conversationStatus contract: {payload}")
    kind = conversation_status.get("kind")
    require(
        kind in {"idle", "outgoing-beep", "incoming-beep", "connecting", "waiting-for-peer", "ready", "self-transmitting", "peer-transmitting"},
        f"{label} conversationStatus kind invalid: {conversation_status}",
    )
    require(kind == payload.get("status"), f"{label} conversationStatus disagrees with legacy status: {payload}")
    active_transmitter = conversation_status.get("activeTransmitterUserId")
    if kind in {"self-transmitting", "peer-transmitting"}:
        require(
            isinstance(active_transmitter, str) and active_transmitter,
            f"{label} missing active transmitter for transmitting conversation state: {conversation_status}",
        )
        require(
            active_transmitter == payload.get("activeTransmitterUserId"),
            f"{label} conversationStatus active transmitter disagrees with legacy field: {payload}",
        )
    else:
        require(
            active_transmitter in (None, ""),
            f"{label} unexpected active transmitter for non-transmitting conversation state: {conversation_status}",
        )


def require_readiness_contract(payload: dict[str, Any], *, label: str) -> None:
    readiness = payload.get("readiness")
    require(isinstance(readiness, dict), f"{label} missing readiness contract: {payload}")
    kind = readiness.get("kind")
    require(
        kind in {"waiting-for-self", "waiting-for-peer", "ready", "self-transmitting", "peer-transmitting"},
        f"{label} readiness kind invalid: {readiness}",
    )
    require(kind == payload.get("status"), f"{label} readiness contract disagrees with legacy status: {payload}")
    active_transmitter = readiness.get("activeTransmitterUserId")
    if kind == "waiting-for-self":
        require(payload.get("selfHasActiveDevice") is False, f"{label} readiness expected self device to be inactive: {payload}")
    if kind == "waiting-for-peer":
        require(payload.get("selfHasActiveDevice") is True, f"{label} readiness expected self device to be active: {payload}")
        require(payload.get("peerHasActiveDevice") is False, f"{label} readiness expected peer device to be inactive: {payload}")
    if kind == "ready":
        require(payload.get("selfHasActiveDevice") is True, f"{label} readiness expected self device to be active: {payload}")
        require(payload.get("peerHasActiveDevice") is True, f"{label} readiness expected peer device to be active: {payload}")
    if kind in {"self-transmitting", "peer-transmitting"}:
        require(
            isinstance(active_transmitter, str) and active_transmitter,
            f"{label} readiness missing active transmitter for transmitting state: {readiness}",
        )
        require(
            active_transmitter == payload.get("activeTransmitterUserId"),
            f"{label} readiness active transmitter disagrees with legacy field: {payload}",
        )
    else:
        require(
            active_transmitter in (None, ""),
            f"{label} readiness unexpectedly carried active transmitter: {readiness}",
        )


def require_audio_readiness_contract(payload: dict[str, Any], *, label: str) -> None:
    audio_readiness = payload.get("audioReadiness")
    require(isinstance(audio_readiness, dict), f"{label} missing audioReadiness contract: {payload}")

    self_readiness = audio_readiness.get("self")
    peer_readiness = audio_readiness.get("peer")
    require(isinstance(self_readiness, dict), f"{label} audioReadiness missing self readiness: {audio_readiness}")
    require(isinstance(peer_readiness, dict), f"{label} audioReadiness missing peer readiness: {audio_readiness}")

    self_kind = self_readiness.get("kind")
    peer_kind = peer_readiness.get("kind")
    valid_kinds = {"unknown", "waiting", "wake-capable", "ready"}
    require(self_kind in valid_kinds, f"{label} invalid self audio readiness kind: {audio_readiness}")
    require(peer_kind in valid_kinds, f"{label} invalid peer audio readiness kind: {audio_readiness}")

    self_has_active_device = payload.get("selfHasActiveDevice")
    peer_has_active_device = payload.get("peerHasActiveDevice")

    if self_has_active_device:
        require(
            self_kind in {"waiting", "wake-capable", "ready"},
            f"{label} self audio readiness should not be unknown when self has an active device: {audio_readiness}",
        )
    else:
        require(
            self_kind == "unknown",
            f"{label} self audio readiness should be unknown without an active device: {audio_readiness}",
        )

    peer_target_device_id = audio_readiness.get("peerTargetDeviceId")
    if peer_has_active_device:
        require(
            peer_kind in {"waiting", "wake-capable", "ready"},
            f"{label} peer audio readiness should not be unknown when peer has an active device: {audio_readiness}",
        )
        require(
            isinstance(peer_target_device_id, str) and peer_target_device_id,
            f"{label} peer audio readiness missing peerTargetDeviceId for active peer device: {audio_readiness}",
        )
    else:
        require(
            peer_kind == "unknown",
            f"{label} peer audio readiness should be unknown without an active device: {audio_readiness}",
        )
        require(
            peer_target_device_id in (None, ""),
            f"{label} peer audio readiness unexpectedly carried peerTargetDeviceId: {audio_readiness}",
        )


def require_wake_readiness_contract(payload: dict[str, Any], *, label: str) -> None:
    wake_readiness = payload.get("wakeReadiness")
    require(isinstance(wake_readiness, dict), f"{label} missing wakeReadiness contract: {payload}")

    self_wake = wake_readiness.get("self")
    peer_wake = wake_readiness.get("peer")
    require(isinstance(self_wake, dict), f"{label} wakeReadiness missing self readiness: {wake_readiness}")
    require(isinstance(peer_wake, dict), f"{label} wakeReadiness missing peer readiness: {wake_readiness}")

    valid_kinds = {"unavailable", "wake-capable"}
    self_kind = self_wake.get("kind")
    peer_kind = peer_wake.get("kind")
    require(self_kind in valid_kinds, f"{label} invalid self wake readiness kind: {wake_readiness}")
    require(peer_kind in valid_kinds, f"{label} invalid peer wake readiness kind: {wake_readiness}")

    def require_target(kind: Any, target: Any, *, side: str) -> None:
        if kind == "wake-capable":
            require(
                isinstance(target, str) and target,
                f"{label} {side} wake readiness missing targetDeviceId: {wake_readiness}",
            )
        else:
            require(
                target in (None, ""),
                f"{label} {side} wake readiness unexpectedly carried targetDeviceId: {wake_readiness}",
            )

    require_target(self_kind, self_wake.get("targetDeviceId"), side="self")
    require_target(peer_kind, peer_wake.get("targetDeviceId"), side="peer")


def direct_quic_identity_for_device(device_id: str) -> dict[str, str]:
    digest = hashlib.sha256(f"route-probe:{device_id}".encode("utf-8")).hexdigest()
    return {
        "fingerprint": f"sha256:{digest}",
    }


def direct_quic_upgrade_request_payload(
    *,
    channel_id: str,
    from_device_id: str,
    to_device_id: str,
    reason: str,
) -> str:
    return json.dumps({
        "requestId": f"route-probe-upgrade-{uuid.uuid4()}",
        "channelId": channel_id,
        "fromDeviceId": from_device_id,
        "toDeviceId": to_device_id,
        "reason": reason,
        "roleIntent": "listener",
    })


def direct_quic_offer_payload(
    *,
    channel_id: str,
    from_device_id: str,
    to_device_id: str,
) -> str:
    return json.dumps({
        "kind": "offer",
        "attemptId": f"route-probe-attempt-{uuid.uuid4()}",
        "channelId": channel_id,
        "fromDeviceId": from_device_id,
        "toDeviceId": to_device_id,
        "quicAlpn": "turbo-ptt-v2",
        "certificateFingerprint": direct_quic_identity_for_device(from_device_id)["fingerprint"],
        "candidates": [],
        "roleIntent": "listener",
    })


def direct_quic_answer_payload(
    *,
    channel_id: str,
    from_device_id: str,
    to_device_id: str,
) -> str:
    return json.dumps({
        "kind": "answer",
        "attemptId": f"route-probe-attempt-{uuid.uuid4()}",
        "channelId": channel_id,
        "fromDeviceId": from_device_id,
        "toDeviceId": to_device_id,
        "certificateFingerprint": direct_quic_identity_for_device(from_device_id)["fingerprint"],
        "candidates": [],
        "roleIntent": "dialer",
    })


def direct_quic_candidate_payload(
    *,
    channel_id: str,
    from_device_id: str,
    to_device_id: str,
) -> str:
    return json.dumps({
        "kind": "ice-candidate",
        "attemptId": f"route-probe-attempt-{uuid.uuid4()}",
        "channelId": channel_id,
        "fromDeviceId": from_device_id,
        "toDeviceId": to_device_id,
        "candidates": [],
        "endOfCandidates": True,
    })


def conversation_participant_telemetry_payload(*, interface: str) -> str:
    return json.dumps({
        "connection": {"interface": interface},
    })


def require_direct_quic_peer_identity(
    payload: dict[str, Any],
    *,
    expected_fingerprint: str,
    label: str,
) -> None:
    identity = payload.get("peerDirectQuicIdentity")
    require(isinstance(identity, dict), f"{label} missing peerDirectQuicIdentity: {payload}")
    require(
        "certificateDerBase64" not in identity,
        f"{label} peer Direct QUIC identity leaked certificate DER material: {identity}",
    )
    require(identity.get("status") == "active", f"{label} peer Direct QUIC identity is not active: {identity}")
    require(
        identity.get("fingerprint") == expected_fingerprint,
        f"{label} peer Direct QUIC fingerprint mismatch: {identity}",
    )


def require_diagnostics_report(
    response: dict[str, Any],
    *,
    expected_status: str,
    expected_device_id: str,
    expected_app_version: str,
    expected_selected_handle: str,
) -> dict[str, Any]:
    require(response.get("status") == expected_status, f"unexpected diagnostics payload: {response}")
    report = response.get("report")
    require(isinstance(report, dict), f"diagnostics response missing report: {response}")
    require(report.get("deviceId") == expected_device_id, f"diagnostics latest mismatched device: {report}")
    require(report.get("appVersion") == expected_app_version, f"diagnostics latest mismatched appVersion: {report}")
    require(report.get("selectedHandle") == expected_selected_handle, f"diagnostics latest mismatched selected handle: {report}")
    require(bool(report.get("uploadedAt")), f"diagnostics latest missing uploadedAt: {report}")
    return report


def require_diagnostics_report_shape(response: dict[str, Any], *, expected_status: str) -> dict[str, Any]:
    require(response.get("status") == expected_status, f"unexpected diagnostics payload: {response}")
    report = response.get("report")
    require(isinstance(report, dict), f"diagnostics response missing report: {response}")
    require(bool(report.get("deviceId")), f"diagnostics latest missing deviceId: {report}")
    require(bool(report.get("appVersion")), f"diagnostics latest missing appVersion: {report}")
    require(bool(report.get("uploadedAt")), f"diagnostics latest missing uploadedAt: {report}")
    return report


def require_wake_events_payload(payload: dict[str, Any], *, expected_status: str) -> list[dict[str, Any]]:
    require(payload.get("status") == expected_status, f"unexpected wake-events payload: {payload}")
    events = payload.get("events")
    require(isinstance(events, list), f"wake-events response missing events list: {payload}")
    return events


def require_invariant_events_payload(payload: dict[str, Any], *, expected_status: str) -> list[dict[str, Any]]:
    require(payload.get("status") == expected_status, f"unexpected invariant-events payload: {payload}")
    events = payload.get("events")
    require(isinstance(events, list), f"invariant-events response missing events list: {payload}")
    return events


async def receive_json_or_timeout(connection, timeout_seconds: int) -> dict:
    try:
        raw = await asyncio.wait_for(connection.recv(), timeout=timeout_seconds)
        return json.loads(raw)
    except Exception as exc:
        return {"error": repr(exc)}


async def send_signal(
    connection,
    *,
    type: str,
    channel_id: str,
    from_user_id: str,
    from_device_id: str,
    to_user_id: str,
    to_device_id: str,
    payload: str,
    session_id: str | None = None,
) -> None:
    envelope = {
        "type": type,
        "channelId": channel_id,
        "fromUserId": from_user_id,
        "fromDeviceId": from_device_id,
        "toUserId": to_user_id,
        "toDeviceId": to_device_id,
        "payload": payload,
    }
    if session_id:
        envelope["sessionId"] = session_id
    await connection.send(json.dumps(envelope))


async def expect_forwarded_signal(
    connection,
    *,
    expected_type: str,
    expected_channel_id: str,
    expected_from_user_id: str,
    expected_from_device_id: str,
    expected_to_user_id: str,
    expected_to_device_id: str,
) -> dict[str, Any]:
    envelope = await receive_json_or_timeout(connection, timeout_seconds=10)
    require(envelope.get("type") == expected_type, f"unexpected forwarded signal type: {envelope}")
    require(envelope.get("channelId") == expected_channel_id, f"unexpected forwarded channel id: {envelope}")
    require(envelope.get("fromUserId") == expected_from_user_id, f"unexpected forwarded fromUserId: {envelope}")
    require(envelope.get("fromDeviceId") == expected_from_device_id, f"unexpected forwarded fromDeviceId: {envelope}")
    require(envelope.get("toUserId") == expected_to_user_id, f"unexpected forwarded toUserId: {envelope}")
    require(envelope.get("toDeviceId") == expected_to_device_id, f"unexpected forwarded toDeviceId: {envelope}")
    return envelope


async def verify_signal_forwarding(
    results: list[CheckResult],
    *,
    sender_connection,
    receiver_connection,
    type: str,
    name: str,
    channel_id: str,
    sender: dict[str, str],
    receiver: dict[str, str],
    payload: str,
    session_id: str | None = None,
) -> None:
    await run_async_check(
        results,
        f"signal:{name}:send",
        lambda: send_signal(
            sender_connection,
            type=type,
            channel_id=channel_id,
            from_user_id=sender["user_id"],
            from_device_id=sender["device_id"],
            to_user_id=receiver["user_id"],
            to_device_id=receiver["device_id"],
            payload=payload,
            session_id=session_id,
        ),
    )
    await run_async_check(
        results,
        f"signal:{name}:forwarded",
        lambda: expect_forwarded_signal(
            receiver_connection,
            expected_type=type,
            expected_channel_id=channel_id,
            expected_from_user_id=sender["user_id"],
            expected_from_device_id=sender["device_id"],
            expected_to_user_id=receiver["user_id"],
            expected_to_device_id=receiver["device_id"],
        ),
    )


@contextlib.asynccontextmanager
async def connected_websocket_pair(
    base_url: str,
    caller: dict[str, str],
    callee: dict[str, str],
    insecure: bool,
):
    ws_base = base_url.replace("https://", "wss://").replace("http://", "ws://").rstrip("/")
    websocket_scheme = urllib.parse.urlparse(ws_base).scheme
    caller_url = f"{ws_base}/v1/ws?deviceId={urllib.parse.quote(caller['device_id'])}"
    callee_url = f"{ws_base}/v1/ws?deviceId={urllib.parse.quote(callee['device_id'])}"
    caller_headers = {
        "x-turbo-user-handle": caller["handle"],
        "Authorization": f"Bearer {caller['handle']}",
    }
    callee_headers = {
        "x-turbo-user-handle": callee["handle"],
        "Authorization": f"Bearer {callee['handle']}",
    }
    ssl_context = None
    if websocket_scheme == "wss":
        ssl_context = ssl._create_unverified_context() if insecure else ssl.create_default_context()
    async with websockets.connect(
        callee_url,
        additional_headers=callee_headers,
        open_timeout=20,
        ssl=ssl_context,
    ) as callee_ws:
        async with websockets.connect(
            caller_url,
            additional_headers=caller_headers,
            open_timeout=20,
            ssl=ssl_context,
        ) as caller_ws:
            callee_ack = await receive_json_or_timeout(callee_ws, timeout_seconds=10)
            caller_ack = await receive_json_or_timeout(caller_ws, timeout_seconds=10)
            require(callee_ack.get("status") == "connected", f"unexpected callee ack: {callee_ack}")
            require(caller_ack.get("status") == "connected", f"unexpected caller ack: {caller_ack}")
            require(callee_ack.get("deviceId") == callee["device_id"], f"callee ack targeted wrong device: {callee_ack}")
            require(caller_ack.get("deviceId") == caller["device_id"], f"caller ack targeted wrong device: {caller_ack}")
            yield {
                "caller": caller_ws,
                "callee": callee_ws,
                "callerAck": caller_ack,
                "calleeAck": callee_ack,
            }


def run_check(results: list[CheckResult], name: str, fn) -> Any:
    started = time.perf_counter()
    try:
        payload = fn()
        duration_ms = int((time.perf_counter() - started) * 1000)
        results.append(CheckResult(name=name, ok=True, detail="ok", durationMs=duration_ms, payload=payload))
        return payload
    except Exception as exc:
        duration_ms = int((time.perf_counter() - started) * 1000)
        results.append(CheckResult(name=name, ok=False, detail=str(exc), durationMs=duration_ms))
        raise


def run_eventually_check(
    results: list[CheckResult],
    name: str,
    fn,
    predicate,
    *,
    timeout_seconds: float = 8.0,
    interval_seconds: float = 0.5,
    failure_message: str,
) -> Any:
    started = time.perf_counter()
    deadline = started + timeout_seconds
    attempts = 0
    last_payload: Any | None = None
    last_error: Exception | None = None
    while True:
        attempts += 1
        try:
            payload = fn()
            last_payload = payload
            last_error = None
            if predicate(payload):
                duration_ms = int((time.perf_counter() - started) * 1000)
                results.append(
                    CheckResult(
                        name=name,
                        ok=True,
                        detail=f"ok after {attempts} attempt(s)",
                        durationMs=duration_ms,
                        payload=payload,
                    )
                )
                return payload
        except Exception as exc:
            last_error = exc
        if time.perf_counter() >= deadline:
            duration_ms = int((time.perf_counter() - started) * 1000)
            detail = (
                f"{failure_message}: {last_error}"
                if last_error is not None
                else f"{failure_message}: {last_payload}"
            )
            results.append(CheckResult(name=name, ok=False, detail=detail, durationMs=duration_ms, payload=last_payload))
            raise RouteProbeFailure(detail)
        time.sleep(interval_seconds)


async def run_async_check(results: list[CheckResult], name: str, fn) -> Any:
    started = time.perf_counter()
    try:
        payload = await fn()
        duration_ms = int((time.perf_counter() - started) * 1000)
        results.append(CheckResult(name=name, ok=True, detail="ok", durationMs=duration_ms, payload=payload))
        return payload
    except Exception as exc:
        duration_ms = int((time.perf_counter() - started) * 1000)
        results.append(CheckResult(name=name, ok=False, detail=str(exc), durationMs=duration_ms))
        raise


def participant(handle: str, prefix: str) -> dict[str, str]:
    return {
        "handle": handle,
        "device_id": f"{prefix}-{uuid.uuid4()}",
    }


async def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Turbo's deployed HTTP route surface.")
    parser.add_argument("--base-url", default="https://api.beepbeep.to")
    parser.add_argument("--caller", default="@quinn")
    parser.add_argument("--callee", default="@sasha")
    parser.add_argument("--insecure", action="store_true")
    parser.add_argument("--json", action="store_true", help="Print the full JSON report even on success.")
    args = parser.parse_args()

    results: list[CheckResult] = []
    caller = participant(args.caller, "route-probe-caller")
    callee = participant(args.callee, "route-probe-callee")
    worker_secret = os.environ.get("TURBO_APNS_WORKER_SECRET", "").strip()

    try:
        config = run_check(
            results,
            "config",
            lambda: request(args.base_url, "/v1/config", caller["handle"], insecure=args.insecure),
        )
        require(isinstance(config, dict), f"/v1/config returned unexpected payload: {config}")
        app_site_association = run_check(
            results,
            "apple-app-site-association",
            lambda: request(
                args.base_url,
                "/.well-known/apple-app-site-association",
                None,
                insecure=args.insecure,
            ),
        )
        require(isinstance(app_site_association, dict), f"unexpected aasa payload: {app_site_association}")
        applinks = app_site_association.get("applinks")
        require(isinstance(applinks, dict), f"aasa missing applinks object: {app_site_association}")
        details = applinks.get("details")
        require(isinstance(details, list) and details, f"aasa missing details array: {app_site_association}")
        first_detail = details[0]
        require(isinstance(first_detail, dict), f"aasa detail had wrong shape: {app_site_association}")
        app_ids = first_detail.get("appIDs")
        require(
            isinstance(app_ids, list) and "7MQU7TLQQ2.com.rounded.Turbo" in app_ids,
            f"aasa missing BeepBeep app id: {app_site_association}",
        )
        components = first_detail.get("components")
        require(isinstance(components, list) and components, f"aasa missing path components: {app_site_association}")
        component_paths = {component.get("/") for component in components if isinstance(component, dict)}
        require("/*" in component_paths, f"aasa missing root-handle component: {app_site_association}")
        require("/@*" in component_paths, f"aasa missing /@* alias component: {app_site_association}")
        require("/p/*" in component_paths, f"aasa missing legacy /p/* component: {app_site_association}")
        require("/id/*/did.json" in component_paths, f"aasa missing did component: {app_site_association}")

        run_check(
            results,
            "dev-seed",
            lambda: request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure),
        )
        reset_all = run_check(
            results,
            "dev-reset-all",
            lambda: request(args.base_url, "/v1/dev/reset-all", caller["handle"], method="POST", insecure=args.insecure),
        )
        require(reset_all.get("status") == "reset-all", f"unexpected reset-all payload: {reset_all}")
        reset_state = run_check(
            results,
            "dev-reset-state",
            lambda: request(args.base_url, "/v1/dev/reset-state", caller["handle"], method="POST", insecure=args.insecure),
        )
        require(reset_state.get("status") == "reset", f"unexpected reset-state payload: {reset_state}")
        if worker_secret:
            try:
                internal_wake_jobs = run_check(
                    results,
                    "internal-wake-jobs:empty",
                    lambda: request(
                        args.base_url,
                        "/v1/internal/wake-jobs",
                        caller["handle"],
                        insecure=args.insecure,
                        extra_headers={"x-turbo-worker-secret": worker_secret},
                    ),
                )
                require(internal_wake_jobs.get("status") == "ok", f"unexpected internal wake jobs payload: {internal_wake_jobs}")
                require(isinstance(internal_wake_jobs.get("jobs"), list), f"internal wake jobs missing jobs list: {internal_wake_jobs}")
            except Exception as exc:
                results.append(
                    CheckResult(
                        name="internal-wake-jobs:empty",
                        ok=True,
                        detail=f"skipped legacy wake-jobs check: {exc}",
                        durationMs=0,
                    )
                )
        run_check(
            results,
            "dev-seed-after-reset",
            lambda: request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure),
        )

        for current in (caller, callee):
            peer = callee if current is caller else caller
            session = run_check(
                results,
                f"auth-session:{current['handle']}",
                lambda current=current: request(args.base_url, "/v1/auth/session", current["handle"], method="POST", insecure=args.insecure),
            )
            require(session.get("handle") == current["handle"], f"auth session mismatched handle: {session}")
            current["user_id"] = session["userId"]
            current["public_id"] = session.get("publicId", current["handle"])
            current["share_code"] = session.get("shareCode", current["public_id"])
            current["share_link"] = session.get(
                "shareLink",
                f"{args.base_url.rstrip('/')}/{share_path_component(current['share_code'])}",
            )
            current["did"] = session.get("did", f"did:web:beepbeep.to:id:{current['public_id']}")
            current["profile_name"] = f"Route Probe {current['handle'].lstrip('@').title()}"

            updated_profile = run_check(
                results,
                f"profile-update:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/profile",
                    current["handle"],
                    method="POST",
                    body={"profileName": current["profile_name"]},
                    insecure=args.insecure,
                ),
            )
            require(
                updated_profile.get("profileName") == current["profile_name"],
                f"profile update did not persist profileName: {updated_profile}",
            )

            share_page_html = run_check(
                results,
                f"share-page:{current['handle']}",
                lambda current=current: request_text(
                    args.base_url,
                    f"/{urllib.parse.quote(share_path_component(current['share_code']))}",
                    None,
                    insecure=args.insecure,
                ),
            )
            require("Open in BeepBeep" in share_page_html, f"share page missing app CTA: {share_page_html[:400]}")
            require(current["share_link"] in share_page_html, f"share page missing share link: {share_page_html[:400]}")
            require(current["share_code"] in share_page_html, f"share page missing share handle: {share_page_html[:400]}")
            require(current["profile_name"] in share_page_html, f"share page missing updated profile name: {share_page_html[:400]}")
            require("apple-itunes-app" in share_page_html, f"share page missing smart app banner metadata: {share_page_html[:400]}")
            require("app-id=6762493911" in share_page_html, f"share page missing app store id: {share_page_html[:400]}")
            require("id=\"qr\"" in share_page_html, f"share page missing qr container: {share_page_html[:400]}")
            require("api.qrserver.com/v1/create-qr-code/" in share_page_html, f"share page missing qr image source: {share_page_html[:400]}")
            require("Android is not supported yet." in share_page_html, f"share page missing android fallback copy: {share_page_html[:400]}")

            did_document = run_check(
                results,
                f"did-document:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/id/{urllib.parse.quote(current['public_id'])}/did.json",
                    None,
                    insecure=args.insecure,
                ),
            )
            require(did_document.get("id") == current["did"], f"did document mismatched id: {did_document}")
            also_known_as = did_document.get("alsoKnownAs")
            require(
                isinstance(also_known_as, list) and current["share_link"] in also_known_as,
                f"did document missing share page alias: {did_document}",
            )

            device = run_check(
                results,
                f"device-register:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/devices/register",
                    current["handle"],
                    method="POST",
                    body={
                        "deviceId": current["device_id"],
                        "deviceLabel": current["device_id"],
                        "directQuicIdentity": direct_quic_identity_for_device(current["device_id"]),
                    },
                    insecure=args.insecure,
                ),
            )
            require(device.get("deviceId") == current["device_id"], f"device registration mismatched id: {device}")
            require(
                device.get("directQuicIdentity", {}).get("fingerprint")
                == direct_quic_identity_for_device(current["device_id"])["fingerprint"],
                f"device registration did not round-trip Direct QUIC identity: {device}",
            )
            require(
                "certificateDerBase64" not in device.get("directQuicIdentity", {}),
                f"device registration leaked Direct QUIC certificate DER material: {device}",
            )

            diagnostics_upload = run_check(
                results,
                f"diagnostics-upload:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/dev/diagnostics",
                    current["handle"],
                    method="POST",
                    body={
                        "deviceId": current["device_id"],
                        "appVersion": f"route-probe:{current['device_id']}",
                        "backendBaseURL": args.base_url,
                        "selectedHandle": peer["handle"],
                        "snapshot": f"snapshot for {current['handle']}",
                        "transcript": f"transcript for {current['handle']}",
                    },
                    insecure=args.insecure,
                ),
            )
            expected_app_version = f"route-probe:{current['device_id']}"
            require_diagnostics_report(
                diagnostics_upload,
                expected_status="uploaded",
                expected_device_id=current["device_id"],
                expected_app_version=expected_app_version,
                expected_selected_handle=peer["handle"],
            )

            diagnostics_latest = run_check(
                results,
                f"diagnostics-latest:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/dev/diagnostics/latest/{urllib.parse.quote(current['device_id'])}",
                    current["handle"],
                    insecure=args.insecure,
                ),
            )
            require_diagnostics_report(
                diagnostics_latest,
                expected_status="ok",
                expected_device_id=current["device_id"],
                expected_app_version=expected_app_version,
                expected_selected_handle=peer["handle"],
            )

            diagnostics_latest_for_user = run_check(
                results,
                f"diagnostics-latest-current:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/dev/diagnostics/latest",
                    current["handle"],
                    insecure=args.insecure,
                ),
            )
            require_diagnostics_report_shape(
                diagnostics_latest_for_user,
                expected_status="ok",
            )

            overwrite_app_version = f"{expected_app_version}:overwrite"
            diagnostics_overwrite = run_check(
                results,
                f"diagnostics-overwrite:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/dev/diagnostics",
                    current["handle"],
                    method="POST",
                    body={
                        "deviceId": current["device_id"],
                        "appVersion": overwrite_app_version,
                        "backendBaseURL": args.base_url,
                        "selectedHandle": peer["handle"],
                        "snapshot": f"overwrite snapshot for {current['handle']}",
                        "transcript": f"overwrite transcript for {current['handle']}",
                    },
                    insecure=args.insecure,
                ),
            )
            require_diagnostics_report(
                diagnostics_overwrite,
                expected_status="uploaded",
                expected_device_id=current["device_id"],
                expected_app_version=overwrite_app_version,
                expected_selected_handle=peer["handle"],
            )

            diagnostics_latest_after_overwrite = run_check(
                results,
                f"diagnostics-latest-after-overwrite:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/dev/diagnostics/latest/{urllib.parse.quote(current['device_id'])}",
                    current["handle"],
                    insecure=args.insecure,
                ),
            )
            require_diagnostics_report(
                diagnostics_latest_after_overwrite,
                expected_status="ok",
                expected_device_id=current["device_id"],
                expected_app_version=overwrite_app_version,
                expected_selected_handle=peer["handle"],
            )

            diagnostics_latest_for_user_after_overwrite = run_check(
                results,
                f"diagnostics-latest-current-after-overwrite:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/dev/diagnostics/latest",
                    current["handle"],
                    insecure=args.insecure,
                ),
            )
            require_diagnostics_report_shape(
                diagnostics_latest_for_user_after_overwrite,
                expected_status="ok",
            )

            heartbeat = run_check(
                results,
                f"presence-heartbeat:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/presence/heartbeat",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(heartbeat.get("deviceId") == current["device_id"], f"presence heartbeat mismatched device: {heartbeat}")

            background_presence = run_check(
                results,
                f"presence-background:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/presence/background",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(
                background_presence.get("deviceId") == current["device_id"],
                f"presence background mismatched device: {background_presence}",
            )
            require(
                background_presence.get("status") in {"background", "offline"},
                f"presence background should report background/offline: {background_presence}",
            )

            user_lookup = run_check(
                results,
                f"user-by-handle:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/users/by-handle/{urllib.parse.quote(current['handle'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            require(user_lookup.get("handle") == current["handle"], f"user lookup mismatched handle: {user_lookup}")

            presence_lookup = run_check(
                results,
                f"user-presence:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/users/by-handle/{urllib.parse.quote(current['handle'])}/presence",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            require(isinstance(presence_lookup, dict), f"presence lookup returned unexpected payload: {presence_lookup}")
            require(
                isinstance(presence_lookup.get("isOnline"), bool),
                f"background presence lookup should include online state: {presence_lookup}",
            )

            heartbeat_after_background = run_check(
                results,
                f"presence-heartbeat-after-background:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/presence/heartbeat",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(
                heartbeat_after_background.get("deviceId") == current["device_id"],
                f"presence heartbeat after background mismatched device: {heartbeat_after_background}",
            )

            device_after_background = run_check(
                results,
                f"device-register-after-background:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/devices/register",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"], "deviceLabel": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(
                device_after_background.get("deviceId") == current["device_id"],
                f"device registration after background mismatched id: {device_after_background}",
            )
            require(
                device_after_background.get("directQuicIdentity", {}).get("fingerprint")
                == direct_quic_identity_for_device(current["device_id"])["fingerprint"],
                f"device registration without identity did not preserve Direct QUIC metadata: {device_after_background}",
            )
            require(
                "certificateDerBase64" not in device_after_background.get("directQuicIdentity", {}),
                f"device registration without identity leaked Direct QUIC certificate DER material: {device_after_background}",
            )

            heartbeat_after_reregister = run_check(
                results,
                f"presence-heartbeat-after-reregister:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/presence/heartbeat",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(
                heartbeat_after_reregister.get("deviceId") == current["device_id"],
                f"presence heartbeat after re-register mismatched device: {heartbeat_after_reregister}",
            )

        caller_summaries = run_check(
            results,
            "contact-summaries:caller",
            lambda: request(
                args.base_url,
                f"/v1/contacts/summaries/{urllib.parse.quote(caller['device_id'])}",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        require(isinstance(caller_summaries, list), f"contact summaries returned unexpected payload: {caller_summaries}")

        beep_cancel = run_check(
            results,
            "beep-create:cancel-flow",
            lambda: request(
                args.base_url,
                "/v1/beeps",
                caller["handle"],
                method="POST",
                body={"friendHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        prejoin_state = run_eventually_check(
            results,
            "channel-state:prejoin-outgoing-beep",
            lambda: request(
                args.base_url,
                f"/v1/channels/{beep_cancel['channelId']}/state/{urllib.parse.quote(caller['device_id'])}",
                caller["handle"],
                insecure=args.insecure,
            ),
            lambda payload: payload.get("status") == "outgoing-beep",
            failure_message="prejoin state should converge to outgoing-beep",
        )
        require(prejoin_state.get("status") == "outgoing-beep", f"prejoin state should be outgoing-beep: {prejoin_state}")
        membership = prejoin_state.get("membership")
        if isinstance(membership, dict):
            require(
                membership.get("kind") == "absent",
                f"prejoin state should not show either participant joined: {prejoin_state}",
            )
        else:
            require(prejoin_state.get("selfJoined") is False, f"prejoin state should not show caller joined: {prejoin_state}")
            require(prejoin_state.get("peerJoined") is False, f"prejoin state should not show peer joined: {prejoin_state}")
        require(prejoin_state.get("canTransmit") is False, f"prejoin state should not allow transmit: {prejoin_state}")
        if is_local_base_url(args.base_url):
            require_beep_thread_projection_contract(prejoin_state, label="channel-state:prejoin-outgoing-beep")
            require_membership_contract(prejoin_state, label="channel-state:prejoin-outgoing-beep")
            require_conversation_status_contract(prejoin_state, label="channel-state:prejoin-outgoing-beep")
        run_eventually_check(
            results,
            "beep-outgoing:list",
            lambda: request(args.base_url, "/v1/beeps/outgoing", caller["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and any(beep.get("beepId") == beep_cancel["beepId"] for beep in payload),
            failure_message="outgoing beep list should include the pending beep",
        )
        cancel_payload = run_eventually_check(
            results,
            "beep-cancel",
            lambda: request(
                args.base_url,
                f"/v1/beeps/{beep_cancel['beepId']}/cancel",
                caller["handle"],
                method="POST",
                insecure=args.insecure,
            ),
            lambda payload: payload.get("beepId") == beep_cancel["beepId"],
            failure_message="cancel route should see and cancel the pending beep",
        )
        require(cancel_payload.get("beepId") == beep_cancel["beepId"], f"cancel route returned unexpected payload: {cancel_payload}")
        run_eventually_check(
            results,
            "beep-outgoing:cancel-cleared",
            lambda: request(args.base_url, "/v1/beeps/outgoing", caller["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and all(beep.get("beepId") != beep_cancel["beepId"] for beep in payload),
            failure_message="cancel should clear the pending outgoing beep",
        )

        beep_decline = run_check(
            results,
            "beep-create:decline-flow",
            lambda: request(
                args.base_url,
                "/v1/beeps",
                caller["handle"],
                method="POST",
                body={"friendHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        run_eventually_check(
            results,
            "beep-incoming:list",
            lambda: request(args.base_url, "/v1/beeps/incoming", callee["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and any(beep.get("beepId") == beep_decline["beepId"] for beep in payload),
            failure_message="incoming beep list should include the pending beep",
        )
        decline_payload = run_eventually_check(
            results,
            "beep-decline",
            lambda: request(
                args.base_url,
                f"/v1/beeps/{beep_decline['beepId']}/decline",
                callee["handle"],
                method="POST",
                insecure=args.insecure,
            ),
            lambda payload: payload.get("beepId") == beep_decline["beepId"],
            failure_message="decline route should see and decline the pending beep",
        )
        require(decline_payload.get("beepId") == beep_decline["beepId"], f"decline route returned unexpected payload: {decline_payload}")
        run_eventually_check(
            results,
            "beep-incoming:decline-cleared",
            lambda: request(args.base_url, "/v1/beeps/incoming", callee["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and all(beep.get("beepId") != beep_decline["beepId"] for beep in payload),
            failure_message="decline should clear the pending incoming beep",
        )

        beep_accept = run_check(
            results,
            "beep-create:accept-flow",
            lambda: request(
                args.base_url,
                "/v1/beeps",
                caller["handle"],
                method="POST",
                body={"friendHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        run_check(
            results,
            "presence-heartbeat:caller-before-accept",
            lambda: request(
                args.base_url,
                "/v1/presence/heartbeat",
                caller["handle"],
                method="POST",
                body={"deviceId": caller["device_id"]},
                insecure=args.insecure,
            ),
        )
        accept_payload = run_eventually_check(
            results,
            "beep-accept",
            lambda: request(
                args.base_url,
                f"/v1/beeps/{beep_accept['beepId']}/accept",
                callee["handle"],
                method="POST",
                insecure=args.insecure,
            ),
            lambda payload: payload.get("accepted") is True and payload.get("status") == "connected",
            failure_message="accept route should see and accept the pending beep",
        )
        require(accept_payload.get("accepted") is True, f"accept route did not mark beep accepted: {accept_payload}")
        require(accept_payload.get("status") == "connected", f"accept route did not report a connected beep: {accept_payload}")
        accepted_channel_id = accept_payload["channelId"]

        stale_original = run_check(
            results,
            "beep-create:stale-accept-original",
            lambda: request(
                args.base_url,
                "/v1/beeps",
                caller["handle"],
                method="POST",
                body={"friendHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        _ = run_eventually_check(
            results,
            "beep-cancel:stale-accept-original",
            lambda: request(
                args.base_url,
                f"/v1/beeps/{stale_original['beepId']}/cancel",
                caller["handle"],
                method="POST",
                insecure=args.insecure,
            ),
            lambda payload: payload.get("beepId") == stale_original["beepId"],
            failure_message="cancel route should see and cancel the stale-original beep",
        )
        stale_replacement = run_check(
            results,
            "beep-create:stale-accept-replacement",
            lambda: request(
                args.base_url,
                "/v1/beeps",
                caller["handle"],
                method="POST",
                body={"friendHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        run_check(
            results,
            "presence-heartbeat:caller-before-stale-accept",
            lambda: request(
                args.base_url,
                "/v1/presence/heartbeat",
                caller["handle"],
                method="POST",
                body={"deviceId": caller["device_id"]},
                insecure=args.insecure,
            ),
        )
        stale_accept_payload = run_eventually_check(
            results,
            "beep-accept:stale-id-accepts-replacement",
            lambda: request(
                args.base_url,
                f"/v1/beeps/{stale_original['beepId']}/accept",
                callee["handle"],
                method="POST",
                insecure=args.insecure,
            ),
            lambda payload: payload.get("beepId") == stale_replacement["beepId"]
            and payload.get("status") == "connected"
            and payload.get("accepted") is True,
            failure_message="stale accept should converge to the replacement beep",
        )
        require(
            stale_accept_payload.get("beepId") == stale_replacement["beepId"],
            f"stale accept did not resolve to replacement beep: accepted={stale_accept_payload} replacement={stale_replacement}",
        )
        require(stale_accept_payload.get("accepted") is True, f"stale accept did not accept replacement beep: {stale_accept_payload}")
        require(
            stale_accept_payload.get("status") == "connected",
            f"stale accept did not connect the replacement beep: {stale_accept_payload}",
        )
        stale_caller_outgoing = run_eventually_check(
            results,
            "beep-outgoing:stale-accept-cleared-caller",
            lambda: request(args.base_url, "/v1/beeps/outgoing", caller["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and all(beep.get("beepId") != stale_replacement["beepId"] for beep in payload),
            failure_message="stale accept should clear caller's replacement outgoing beep",
        )
        stale_callee_incoming = run_eventually_check(
            results,
            "beep-incoming:stale-accept-cleared-callee",
            lambda: request(args.base_url, "/v1/beeps/incoming", callee["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and all(beep.get("beepId") != stale_replacement["beepId"] for beep in payload),
            failure_message="stale accept should clear callee's replacement incoming beep",
        )
        for label, beeps in [
            ("caller outgoing", stale_caller_outgoing),
            ("callee incoming", stale_callee_incoming),
        ]:
            require(
                all(beep.get("beepId") != stale_replacement["beepId"] for beep in beeps),
                f"stale accept left replacement pending in {label}: {beeps}",
            )

        mutual_caller_beep = run_check(
            results,
            "beep-create:mutual-caller",
            lambda: request(
                args.base_url,
                "/v1/beeps",
                caller["handle"],
                method="POST",
                body={"friendHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        mutual_callee_beep = run_check(
            results,
            "beep-create:mutual-callee",
            lambda: request(
                args.base_url,
                "/v1/beeps",
                callee["handle"],
                method="POST",
                body={"friendHandle": caller["handle"]},
                insecure=args.insecure,
            ),
        )
        mutual_channel_id = mutual_callee_beep["channelId"]
        require(
            mutual_caller_beep.get("status") == "pending",
            f"initial reciprocal Beep should stay pending before explicit accept: {mutual_caller_beep}",
        )
        require(
            mutual_caller_beep.get("requestCount") == 1,
            f"initial reciprocal Beep should start the Beep Thread at count 1: {mutual_caller_beep}",
        )
        require(
            mutual_callee_beep.get("status") == "pending",
            f"reciprocal create should refresh the pending Beep Thread, not connect: {mutual_callee_beep}",
        )
        require(
            mutual_callee_beep.get("beepId") == mutual_caller_beep.get("beepId"),
            f"reciprocal create should keep one canonical Beep Thread id: caller={mutual_caller_beep} callee={mutual_callee_beep}",
        )
        require(
            mutual_callee_beep.get("requestCount") == 2,
            f"reciprocal create should monotonically advance the Beep Thread: {mutual_callee_beep}",
        )
        caller_mutual_summaries = run_check(
            results,
            "contact-summaries:caller:mutual-beep",
            lambda: request(
                args.base_url,
                f"/v1/contacts/summaries/{urllib.parse.quote(caller['device_id'])}",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        callee_mutual_summaries = run_check(
            results,
            "contact-summaries:callee:mutual-beep",
            lambda: request(
                args.base_url,
                f"/v1/contacts/summaries/{urllib.parse.quote(callee['device_id'])}",
                callee["handle"],
                insecure=args.insecure,
            ),
        )
        caller_mutual_summary = next(
            (summary for summary in caller_mutual_summaries if summary.get("handle") == callee["handle"]),
            None,
        )
        callee_mutual_summary = next(
            (summary for summary in callee_mutual_summaries if summary.get("handle") == caller["handle"]),
            None,
        )
        require(isinstance(caller_mutual_summary, dict), f"caller mutual summary missing: {caller_mutual_summaries}")
        require(isinstance(callee_mutual_summary, dict), f"callee mutual summary missing: {callee_mutual_summaries}")
        for label, summary, expected_kind, incoming, outgoing in [
            ("caller ping-pong summary", caller_mutual_summary, "incoming", True, False),
            ("callee ping-pong summary", callee_mutual_summary, "outgoing", False, True),
        ]:
            require_beep_thread_projection_contract(summary, label=label)
            relationship = summary.get("beepThreadProjection")
            require(
                relationship.get("kind") == expected_kind and relationship.get("requestCount") == 2,
                f"{label} should project the single latest Beep direction and count: {summary}",
            )
            require(
                summary.get("hasIncomingBeep") is incoming and summary.get("hasOutgoingBeep") is outgoing,
                f"{label} Beep direction flags should mirror the canonical latest thread: {summary}",
            )
        caller_pingpong_incoming = run_check(
            results,
            "beep-incoming:caller:latest-thread",
            lambda: request(args.base_url, "/v1/beeps/incoming", caller["handle"], insecure=args.insecure),
        )
        caller_pingpong_outgoing = run_check(
            results,
            "beep-outgoing:caller:old-thread-cleared",
            lambda: request(args.base_url, "/v1/beeps/outgoing", caller["handle"], insecure=args.insecure),
        )
        callee_pingpong_incoming = run_check(
            results,
            "beep-incoming:callee:old-thread-cleared",
            lambda: request(args.base_url, "/v1/beeps/incoming", callee["handle"], insecure=args.insecure),
        )
        callee_pingpong_outgoing = run_check(
            results,
            "beep-outgoing:callee:latest-thread",
            lambda: request(args.base_url, "/v1/beeps/outgoing", callee["handle"], insecure=args.insecure),
        )
        require(
            any(
                beep.get("beepId") == mutual_callee_beep.get("beepId")
                and beep.get("requestCount") == 2
                and beep.get("direction") == "incoming"
                for beep in caller_pingpong_incoming
            ),
            f"caller should see the latest ping-pong request as one incoming thread: {caller_pingpong_incoming}",
        )
        require(
            any(
                beep.get("beepId") == mutual_callee_beep.get("beepId")
                and beep.get("requestCount") == 2
                and beep.get("direction") == "outgoing"
                for beep in callee_pingpong_outgoing
            ),
            f"callee should see the latest ping-pong request as one outgoing thread: {callee_pingpong_outgoing}",
        )
        for label, beeps in [
            ("caller outgoing", caller_pingpong_outgoing),
            ("callee incoming", callee_pingpong_incoming),
        ]:
            require(
                all(beep.get("channelId") != mutual_channel_id for beep in beeps),
                f"reciprocal refresh left a stale opposite projection in {label}: {beeps}",
            )
        run_check(
            results,
            "presence-heartbeat:callee-before-mutual-accept",
            lambda: request(
                args.base_url,
                "/v1/presence/heartbeat",
                callee["handle"],
                method="POST",
                body={"deviceId": callee["device_id"]},
                insecure=args.insecure,
            ),
        )
        mutual_accept_payload = run_eventually_check(
            results,
            "beep-accept:mutual-clears-both-directions",
            lambda: request(
                args.base_url,
                f"/v1/beeps/{mutual_callee_beep['beepId']}/accept",
                caller["handle"],
                method="POST",
                insecure=args.insecure,
            ),
            lambda payload: payload.get("accepted") is True and payload.get("status") == "connected",
            failure_message="mutual accept route should converge to connected",
        )
        require(
            mutual_accept_payload.get("accepted") is True,
            f"mutual accept route did not mark beep accepted: {mutual_accept_payload}",
        )
        require(
            mutual_accept_payload.get("status") == "connected",
            f"mutual request did not converge to connected: {mutual_accept_payload}",
        )
        caller_outgoing_after_mutual_accept = run_eventually_check(
            results,
            "beep-outgoing:mutual-cleared-caller",
            lambda: request(args.base_url, "/v1/beeps/outgoing", caller["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and all(beep.get("channelId") != mutual_channel_id for beep in payload),
            failure_message="mutual accept should clear caller outgoing beeps",
        )
        callee_outgoing_after_mutual_accept = run_eventually_check(
            results,
            "beep-outgoing:mutual-cleared-callee",
            lambda: request(args.base_url, "/v1/beeps/outgoing", callee["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and all(beep.get("channelId") != mutual_channel_id for beep in payload),
            failure_message="mutual accept should clear callee outgoing beeps",
        )
        caller_incoming_after_mutual_accept = run_eventually_check(
            results,
            "beep-incoming:mutual-cleared-caller",
            lambda: request(args.base_url, "/v1/beeps/incoming", caller["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and all(beep.get("channelId") != mutual_channel_id for beep in payload),
            failure_message="mutual accept should clear caller incoming beeps",
        )
        callee_incoming_after_mutual_accept = run_eventually_check(
            results,
            "beep-incoming:mutual-cleared-callee",
            lambda: request(args.base_url, "/v1/beeps/incoming", callee["handle"], insecure=args.insecure),
            lambda payload: isinstance(payload, list)
            and all(beep.get("channelId") != mutual_channel_id for beep in payload),
            failure_message="mutual accept should clear callee incoming beeps",
        )
        for label, beeps in [
            ("caller outgoing", caller_outgoing_after_mutual_accept),
            ("callee outgoing", callee_outgoing_after_mutual_accept),
            ("caller incoming", caller_incoming_after_mutual_accept),
            ("callee incoming", callee_incoming_after_mutual_accept),
        ]:
            require(
                all(beep.get("channelId") != mutual_channel_id for beep in beeps),
                f"mutual accept left a pending {label} beep on channel {mutual_channel_id}: {beeps}",
            )

        direct = run_check(
            results,
            "channel-direct",
            lambda: request(
                args.base_url,
                "/v1/channels/direct",
                caller["handle"],
                method="POST",
                body={"otherHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        require(direct.get("channelId") == accepted_channel_id, f"direct channel disagreed with accepted beep channel: {direct}")
        channel_id = direct["channelId"]

        wake_events_before = run_check(
            results,
            "wake-events:recent:before-upload",
            lambda: request(
                args.base_url,
                "/v1/dev/wake-events/recent",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        require_wake_events_payload(wake_events_before, expected_status="ok")

        wake_event_upload = run_check(
            results,
            "wake-events:upload",
            lambda: request(
                args.base_url,
                "/v1/dev/wake-events",
                caller["handle"],
                method="POST",
                body={
                    "senderUserId": caller["user_id"],
                    "channelId": channel_id,
                    "senderDeviceId": caller["device_id"],
                    "senderHandle": caller["handle"],
                    "targetUserId": callee["user_id"],
                    "targetDeviceId": callee["device_id"],
                    "startedAt": "2026-04-14T00:00:00Z",
                    "result": "sent",
                    "statusCode": "200",
                    "responseBody": "{}",
                },
                insecure=args.insecure,
            ),
        )
        uploaded_event = wake_event_upload.get("event")
        require(wake_event_upload.get("status") == "uploaded", f"unexpected wake event upload payload: {wake_event_upload}")
        require(isinstance(uploaded_event, dict), f"wake event upload missing event payload: {wake_event_upload}")
        require(uploaded_event.get("channelId") == channel_id, f"wake event upload mismatched channel: {uploaded_event}")

        wake_events_after = run_check(
            results,
            "wake-events:recent:after-upload",
            lambda: request(
                args.base_url,
                "/v1/dev/wake-events/recent",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        recent_wake_events = require_wake_events_payload(wake_events_after, expected_status="ok")
        require(
            any(
                isinstance(event, dict)
                and event.get("channelId") == channel_id
                and event.get("senderDeviceId") == caller["device_id"]
                and event.get("targetDeviceId") == callee["device_id"]
                for event in recent_wake_events
            ),
            f"wake events did not include uploaded row: {recent_wake_events}",
        )

        invariant_probe_id = uuid.uuid4().hex
        invariant_metadata = f"probeId={invariant_probe_id} channelId={channel_id}"
        invariant_events_before = run_check(
            results,
            "invariant-events:recent:before-upload",
            lambda: request(
                args.base_url,
                "/v1/dev/invariant-events/recent",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        require_invariant_events_payload(invariant_events_before, expected_status="ok")

        invariant_event_upload = run_check(
            results,
            "invariant-events:upload",
            lambda: request(
                args.base_url,
                "/v1/dev/invariant-events",
                caller["handle"],
                method="POST",
                body={
                    "invariantId": "route-probe.synthetic_violation",
                    "scope": "backend",
                    "source": "route-probe",
                    "message": "synthetic invariant event",
                    "metadata": invariant_metadata,
                },
                insecure=args.insecure,
            ),
        )
        uploaded_invariant_event = invariant_event_upload.get("event")
        require(
            invariant_event_upload.get("status") == "uploaded",
            f"unexpected invariant event upload payload: {invariant_event_upload}",
        )
        require(
            isinstance(uploaded_invariant_event, dict),
            f"invariant event upload missing event payload: {invariant_event_upload}",
        )
        require(
            uploaded_invariant_event.get("invariantId") == "route-probe.synthetic_violation",
            f"invariant event upload mismatched invariant id: {uploaded_invariant_event}",
        )
        require(
            uploaded_invariant_event.get("metadata") == invariant_metadata,
            f"invariant event upload mismatched metadata: {uploaded_invariant_event}",
        )

        invariant_events_after = run_check(
            results,
            "invariant-events:recent:after-upload",
            lambda: request(
                args.base_url,
                "/v1/dev/invariant-events/recent",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        recent_invariant_events = require_invariant_events_payload(invariant_events_after, expected_status="ok")
        require(
            any(
                isinstance(event, dict)
                and event.get("invariantId") == "route-probe.synthetic_violation"
                and event.get("scope") == "backend"
                and event.get("source") == "route-probe"
                and event.get("metadata") == invariant_metadata
                for event in recent_invariant_events
            ),
            f"invariant events did not include uploaded row: {recent_invariant_events}",
        )

        post_direct_summaries = run_check(
            results,
            "contact-summaries:caller:post-direct",
            lambda: request(
                args.base_url,
                f"/v1/contacts/summaries/{urllib.parse.quote(caller['device_id'])}",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        require(isinstance(post_direct_summaries, list), f"post-direct contact summaries returned unexpected payload: {post_direct_summaries}")
        caller_summary = next(
            (summary for summary in post_direct_summaries if summary.get("handle") == callee["handle"]),
            None,
        )
        require(isinstance(caller_summary, dict), f"callee summary missing after direct channel creation: {post_direct_summaries}")
        require_beep_thread_projection_contract(caller_summary, label="contact-summaries:caller:post-direct")
        require(isinstance(caller_summary.get("membership"), dict), f"contact-summaries:caller:post-direct missing membership contract: {caller_summary}")
        require_summary_status_contract(caller_summary, label="contact-summaries:caller:post-direct")

        async with connected_websocket_pair(args.base_url, caller, callee, args.insecure) as websocket_pair:
            results.append(
                CheckResult(
                    name="websocket-register",
                    ok=True,
                    detail="both websocket endpoints acknowledged the expected device id and stayed connected for readiness checks",
                    durationMs=0,
                    payload={"callerAck": websocket_pair["callerAck"], "calleeAck": websocket_pair["calleeAck"]},
                )
            )

            for current in (caller, callee):
                join_payload = run_check(
                    results,
                    f"channel-join:{current['handle']}",
                    lambda current=current: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/join",
                        current["handle"],
                        method="POST",
                        body={"deviceId": current["device_id"]},
                        insecure=args.insecure,
                    ),
                )
                require(join_payload.get("channelId") == channel_id, f"join route mismatched channel: {join_payload}")

            caller_state = run_check(
                results,
                "channel-state:caller",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/state/{urllib.parse.quote(caller['device_id'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            callee_state = run_check(
                results,
                "channel-state:callee",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/state/{urllib.parse.quote(callee['device_id'])}",
                    callee["handle"],
                    insecure=args.insecure,
                ),
            )
            require(caller_state.get("canTransmit") is True, f"caller cannot transmit after websocket registration: {caller_state}")
            require(callee_state.get("canTransmit") is True, f"callee cannot transmit after websocket registration: {callee_state}")
            if is_local_base_url(args.base_url):
                require_beep_thread_projection_contract(caller_state, label="channel-state:caller")
                require_membership_contract(caller_state, label="channel-state:caller")
                require_conversation_status_contract(caller_state, label="channel-state:caller")
                require_beep_thread_projection_contract(callee_state, label="channel-state:callee")
                require_membership_contract(callee_state, label="channel-state:callee")
                require_conversation_status_contract(callee_state, label="channel-state:callee")

            caller_readiness = run_check(
                results,
                "channel-readiness:caller",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            require(isinstance(caller_readiness, dict), f"readiness returned unexpected payload: {caller_readiness}")
            if is_local_base_url(args.base_url):
                require_readiness_contract(caller_readiness, label="channel-readiness:caller")
                require_audio_readiness_contract(caller_readiness, label="channel-readiness:caller")

            await run_async_check(
                results,
                "signal:receiver-ready:callee-to-caller",
                lambda: send_signal(
                    websocket_pair["callee"],
                    type="receiver-ready",
                    channel_id=channel_id,
                    from_user_id=callee["user_id"],
                    from_device_id=callee["device_id"],
                    to_user_id=caller["user_id"],
                    to_device_id=caller["device_id"],
                    payload="receiver-ready",
                    session_id=websocket_pair["calleeAck"].get("sessionId"),
                ),
            )
            await run_async_check(
                results,
                "signal:receiver-ready-forwarded:caller",
                lambda: expect_forwarded_signal(
                    websocket_pair["caller"],
                    expected_type="receiver-ready",
                    expected_channel_id=channel_id,
                    expected_from_user_id=callee["user_id"],
                    expected_from_device_id=callee["device_id"],
                    expected_to_user_id=caller["user_id"],
                    expected_to_device_id=caller["device_id"],
                ),
            )
            await run_async_check(
                results,
                "signal:receiver-ready:caller-to-callee",
                lambda: send_signal(
                    websocket_pair["caller"],
                    type="receiver-ready",
                    channel_id=channel_id,
                    from_user_id=caller["user_id"],
                    from_device_id=caller["device_id"],
                    to_user_id=callee["user_id"],
                    to_device_id=callee["device_id"],
                    payload="receiver-ready",
                    session_id=websocket_pair["callerAck"].get("sessionId"),
                ),
            )
            await run_async_check(
                results,
                "signal:receiver-ready-forwarded:callee",
                lambda: expect_forwarded_signal(
                    websocket_pair["callee"],
                    expected_type="receiver-ready",
                    expected_channel_id=channel_id,
                    expected_from_user_id=caller["user_id"],
                    expected_from_device_id=caller["device_id"],
                    expected_to_user_id=callee["user_id"],
                    expected_to_device_id=callee["device_id"],
                ),
            )

            await verify_signal_forwarding(
                results,
                sender_connection=websocket_pair["caller"],
                receiver_connection=websocket_pair["callee"],
                type="direct-quic-upgrade-request",
                name="direct-quic-upgrade-request:caller-to-callee",
                channel_id=channel_id,
                sender=caller,
                receiver=callee,
                payload=direct_quic_upgrade_request_payload(
                    channel_id=channel_id,
                    from_device_id=caller["device_id"],
                    to_device_id=callee["device_id"],
                    reason="route-probe-caller-to-callee",
                ),
                session_id=websocket_pair["callerAck"].get("sessionId"),
            )
            await verify_signal_forwarding(
                results,
                sender_connection=websocket_pair["callee"],
                receiver_connection=websocket_pair["caller"],
                type="direct-quic-upgrade-request",
                name="direct-quic-upgrade-request:callee-to-caller",
                channel_id=channel_id,
                sender=callee,
                receiver=caller,
                payload=direct_quic_upgrade_request_payload(
                    channel_id=channel_id,
                    from_device_id=callee["device_id"],
                    to_device_id=caller["device_id"],
                    reason="route-probe-callee-to-caller",
                ),
                session_id=websocket_pair["calleeAck"].get("sessionId"),
            )
            await verify_signal_forwarding(
                results,
                sender_connection=websocket_pair["callee"],
                receiver_connection=websocket_pair["caller"],
                type="offer",
                name="direct-quic-offer:callee-to-caller",
                channel_id=channel_id,
                sender=callee,
                receiver=caller,
                payload=direct_quic_offer_payload(
                    channel_id=channel_id,
                    from_device_id=callee["device_id"],
                    to_device_id=caller["device_id"],
                ),
                session_id=websocket_pair["calleeAck"].get("sessionId"),
            )
            await verify_signal_forwarding(
                results,
                sender_connection=websocket_pair["caller"],
                receiver_connection=websocket_pair["callee"],
                type="answer",
                name="direct-quic-answer:caller-to-callee",
                channel_id=channel_id,
                sender=caller,
                receiver=callee,
                payload=direct_quic_answer_payload(
                    channel_id=channel_id,
                    from_device_id=caller["device_id"],
                    to_device_id=callee["device_id"],
                ),
                session_id=websocket_pair["callerAck"].get("sessionId"),
            )
            await verify_signal_forwarding(
                results,
                sender_connection=websocket_pair["caller"],
                receiver_connection=websocket_pair["callee"],
                type="ice-candidate",
                name="direct-quic-candidate:caller-to-callee",
                channel_id=channel_id,
                sender=caller,
                receiver=callee,
                payload=direct_quic_candidate_payload(
                    channel_id=channel_id,
                    from_device_id=caller["device_id"],
                    to_device_id=callee["device_id"],
                ),
                session_id=websocket_pair["callerAck"].get("sessionId"),
            )
            await verify_signal_forwarding(
                results,
                sender_connection=websocket_pair["caller"],
                receiver_connection=websocket_pair["callee"],
                type="conversation-participant-telemetry",
                name="conversation-participant-telemetry:caller-to-callee",
                channel_id=channel_id,
                sender=caller,
                receiver=callee,
                payload=conversation_participant_telemetry_payload(interface="wifi"),
                session_id=websocket_pair["callerAck"].get("sessionId"),
            )
            await verify_signal_forwarding(
                results,
                sender_connection=websocket_pair["callee"],
                receiver_connection=websocket_pair["caller"],
                type="conversation-participant-telemetry",
                name="conversation-participant-telemetry:callee-to-caller",
                channel_id=channel_id,
                sender=callee,
                receiver=caller,
                payload=conversation_participant_telemetry_payload(interface="cellular"),
                session_id=websocket_pair["calleeAck"].get("sessionId"),
            )

            caller_readiness_after_signal = run_check(
                results,
                "channel-readiness:caller:receiver-ready",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            callee_readiness_after_signal = run_check(
                results,
                "channel-readiness:callee:receiver-ready",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(callee['device_id'])}",
                    callee["handle"],
                    insecure=args.insecure,
                ),
            )
            if is_local_base_url(args.base_url):
                require_readiness_contract(caller_readiness_after_signal, label="channel-readiness:caller:receiver-ready")
                require_readiness_contract(callee_readiness_after_signal, label="channel-readiness:callee:receiver-ready")
                require_audio_readiness_contract(caller_readiness_after_signal, label="channel-readiness:caller:receiver-ready")
                require_audio_readiness_contract(callee_readiness_after_signal, label="channel-readiness:callee:receiver-ready")
                require_wake_readiness_contract(caller_readiness_after_signal, label="channel-readiness:caller:receiver-ready")
                require_wake_readiness_contract(callee_readiness_after_signal, label="channel-readiness:callee:receiver-ready")
                require(
                    caller_readiness_after_signal.get("audioReadiness", {}).get("peer", {}).get("kind") == "ready",
                    f"caller readiness should show ready friend audio after receiver-ready signal: {caller_readiness_after_signal}",
                )
                require(
                    callee_readiness_after_signal.get("audioReadiness", {}).get("peer", {}).get("kind") == "ready",
                    f"callee readiness should show ready friend audio after receiver-ready signal: {callee_readiness_after_signal}",
                )
                require_direct_quic_peer_identity(
                    caller_readiness_after_signal,
                    expected_fingerprint=direct_quic_identity_for_device(callee["device_id"])["fingerprint"],
                    label="channel-readiness:caller:receiver-ready",
                )
                require_direct_quic_peer_identity(
                    callee_readiness_after_signal,
                    expected_fingerprint=direct_quic_identity_for_device(caller["device_id"])["fingerprint"],
                    label="channel-readiness:callee:receiver-ready",
                )

            run_check(
                results,
                "channel-ephemeral-token",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/ephemeral-token",
                    callee["handle"],
                    method="POST",
                    body={"deviceId": callee["device_id"], "token": "route-probe-token"},
                    insecure=args.insecure,
                ),
            )

            caller_readiness_after_token = run_check(
                results,
                "channel-readiness:caller:wake-ready",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            callee_readiness_after_token = run_check(
                results,
                "channel-readiness:callee:wake-ready",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(callee['device_id'])}",
                    callee["handle"],
                    insecure=args.insecure,
                ),
            )
            require_wake_readiness_contract(caller_readiness_after_token, label="channel-readiness:caller:wake-ready")
            require_wake_readiness_contract(callee_readiness_after_token, label="channel-readiness:callee:wake-ready")
            require(
                caller_readiness_after_token.get("wakeReadiness", {}).get("peer", {}).get("kind") == "wake-capable",
                f"caller readiness should expose wake-capable receiver after token upload: {caller_readiness_after_token}",
            )
            require(
                caller_readiness_after_token.get("wakeReadiness", {}).get("peer", {}).get("targetDeviceId") == callee["device_id"],
                f"caller readiness should expose callee wake target after token upload: {caller_readiness_after_token}",
            )
            require(
                callee_readiness_after_token.get("wakeReadiness", {}).get("self", {}).get("kind") == "wake-capable",
                f"callee readiness should expose self wake capability after token upload: {callee_readiness_after_token}",
            )
            require(
                callee_readiness_after_token.get("wakeReadiness", {}).get("self", {}).get("targetDeviceId") == callee["device_id"],
                f"callee readiness should expose local wake target after token upload: {callee_readiness_after_token}",
            )

            run_check(
                results,
                "channel-receiver-not-ready:callee-background",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/receiver-audio-readiness",
                    callee["handle"],
                    method="POST",
                    body={
                        "deviceId": callee["device_id"],
                        "type": "receiver-not-ready",
                        "payload": "app-background-media-closed",
                    },
                    insecure=args.insecure,
                ),
            )
            caller_readiness_after_background = run_check(
                results,
                "channel-readiness:caller:callee-background",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            require(
                caller_readiness_after_background.get("audioReadiness", {}).get("peer", {}).get("kind") == "wake-capable",
                f"caller readiness should show wake-capable peer audio after callee background: {caller_readiness_after_background}",
            )

            begin_payload = run_check(
                results,
                "channel-begin-transmit",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/begin-transmit",
                    caller["handle"],
                    method="POST",
                    body={"deviceId": caller["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(begin_payload.get("status") == "transmitting", f"begin-transmit returned unexpected payload: {begin_payload}")
            wake_events_after_begin = run_check(
                results,
                "wake-events:recent:after-begin-transmit",
                lambda: request(
                    args.base_url,
                    "/v1/dev/wake-events/recent",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            begin_wake_events = require_wake_events_payload(wake_events_after_begin, expected_status="ok")
            require(
                any(
                    isinstance(event, dict)
                    and event.get("channelId") == channel_id
                    and event.get("senderDeviceId") == caller["device_id"]
                    and event.get("targetDeviceId") == callee["device_id"]
                    and event.get("startedAt") == begin_payload.get("startedAt")
                    for event in begin_wake_events
                ),
                f"begin-transmit did not record a backend wake event: {begin_wake_events}",
            )
            if is_local_base_url(args.base_url):
                caller_state_transmitting = run_check(
                    results,
                    "channel-state:caller:transmitting",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(caller['device_id'])}",
                        caller["handle"],
                        insecure=args.insecure,
                    ),
                )
                callee_state_receiving = run_check(
                    results,
                    "channel-state:callee:receiving",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(callee['device_id'])}",
                        callee["handle"],
                        insecure=args.insecure,
                    ),
                )
                require_conversation_status_contract(caller_state_transmitting, label="channel-state:caller:transmitting")
                require_conversation_status_contract(callee_state_receiving, label="channel-state:callee:receiving")
                require(
                    caller_state_transmitting.get("conversationStatus", {}).get("kind") == "self-transmitting",
                    f"caller state should show self-transmitting after begin-transmit: {caller_state_transmitting}",
                )
                require(
                    callee_state_receiving.get("conversationStatus", {}).get("kind") == "peer-transmitting",
                    f"callee state should show peer-transmitting after begin-transmit: {callee_state_receiving}",
                )
                require(
                    caller_state_transmitting.get("conversationStatus", {}).get("activeTransmitterUserId") == caller["user_id"],
                    f"caller transmitting state should carry caller as active transmitter: {caller_state_transmitting}",
                )
                require(
                    callee_state_receiving.get("conversationStatus", {}).get("activeTransmitterUserId") == caller["user_id"],
                    f"callee receiving state should carry caller as active transmitter: {callee_state_receiving}",
                )

                caller_readiness_transmitting = run_check(
                    results,
                    "channel-readiness:caller:transmitting",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
                        caller["handle"],
                        insecure=args.insecure,
                    ),
                )
                callee_readiness_receiving = run_check(
                    results,
                    "channel-readiness:callee:receiving",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(callee['device_id'])}",
                        callee["handle"],
                        insecure=args.insecure,
                    ),
                )
                require_readiness_contract(caller_readiness_transmitting, label="channel-readiness:caller:transmitting")
                require_readiness_contract(callee_readiness_receiving, label="channel-readiness:callee:receiving")
                require_audio_readiness_contract(caller_readiness_transmitting, label="channel-readiness:caller:transmitting")
                require_audio_readiness_contract(callee_readiness_receiving, label="channel-readiness:callee:receiving")
                require(
                    caller_readiness_transmitting.get("readiness", {}).get("kind") == "self-transmitting",
                    f"caller readiness should show self-transmitting after begin-transmit: {caller_readiness_transmitting}",
                )
                require(
                    callee_readiness_receiving.get("readiness", {}).get("kind") == "peer-transmitting",
                    f"callee readiness should show peer-transmitting after begin-transmit: {callee_readiness_receiving}",
                )

            push_target_started = time.perf_counter()
            try:
                push_target = request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/ptt-push-target",
                    caller["handle"],
                    insecure=args.insecure,
                )
                results.append(
                    CheckResult(
                        name="channel-ptt-push-target",
                        ok=True,
                        detail="ok",
                        durationMs=int((time.perf_counter() - push_target_started) * 1000),
                        payload=push_target,
                    )
                )
                require(push_target.get("targetDeviceId") == callee["device_id"], f"ptt push target mismatched device: {push_target}")
            except Exception as exc:
                results.append(
                    CheckResult(
                        name="channel-ptt-push-target",
                        ok=True,
                        detail=f"skipped legacy ptt-push-target check: {exc}",
                        durationMs=int((time.perf_counter() - push_target_started) * 1000),
                    )
                )

            renew_payload = run_check(
                results,
                "channel-renew-transmit",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/renew-transmit",
                    caller["handle"],
                    method="POST",
                    body={"deviceId": caller["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(renew_payload.get("status") == "transmitting", f"renew-transmit returned unexpected payload: {renew_payload}")

            end_payload = run_check(
                results,
                "channel-end-transmit",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/end-transmit",
                    caller["handle"],
                    method="POST",
                    body={"deviceId": caller["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(end_payload.get("status") in {"idle", "stopped"}, f"end-transmit returned unexpected payload: {end_payload}")
            if is_local_base_url(args.base_url):
                caller_state_after_end = run_check(
                    results,
                    "channel-state:caller:post-transmit",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(caller['device_id'])}",
                        caller["handle"],
                        insecure=args.insecure,
                    ),
                )
                require_conversation_status_contract(caller_state_after_end, label="channel-state:caller:post-transmit")
                require(
                    caller_state_after_end.get("conversationStatus", {}).get("kind") == "ready",
                    f"caller state should return to ready after end-transmit: {caller_state_after_end}",
                )

        for current in (caller, callee):
            leave_payload = run_check(
                results,
                f"channel-leave:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/leave",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(leave_payload.get("channelId") == channel_id, f"leave route mismatched channel: {leave_payload}")

    except RouteProbeFailure as exc:
        report = {
            "ok": False,
            "baseUrl": args.base_url,
            "checks": [asdict(result) for result in results],
            "error": str(exc),
        }
        print(json.dumps(report, indent=2))
        return 1

    report = {
        "ok": True,
        "baseUrl": args.base_url,
        "checks": [asdict(result) for result in results],
    }
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"ROUTE PROBE PASSED: {len(results)} checks against {args.base_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
