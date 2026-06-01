#!/usr/bin/env python3

import argparse
import asyncio
import contextlib
import json
import ssl
import time
import urllib.parse
import uuid
from dataclasses import asdict, dataclass, field
from typing import Any

from route_probe import request

try:
    import websockets
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "The `websockets` package is required. Install it with `python3 -m pip install websockets`."
    ) from exc


@dataclass
class ProbeEvent:
    timestamp: float
    participant: str
    kind: str
    detail: str
    payload: dict[str, Any] | None = None


@dataclass
class HTTPActionResult:
    participant: str
    action: str
    iteration: int
    ok: bool
    durationMs: int
    detail: str


@dataclass
class ConnectionSummary:
    participant: str
    handle: str
    deviceId: str
    connectMs: int
    ackMs: int
    ackPayload: dict[str, Any]
    closedUnexpectedly: bool = False
    closeCode: int | None = None
    closeReason: str | None = None
    connectedDurationMs: int | None = None
    messagesObserved: int = 0
    noticesObserved: int = 0
    events: list[ProbeEvent] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Probe hosted Turbo websocket stability over time.")
    parser.add_argument("--base-url", default="https://staging.beepbeep.to")
    parser.add_argument("--caller", default="@quinn")
    parser.add_argument("--callee", default="@sasha")
    parser.add_argument("--duration", type=int, default=90, help="Seconds to hold the websocket pair open.")
    parser.add_argument(
        "--heartbeat-interval",
        type=int,
        default=20,
        help="Seconds between presence-heartbeat writes per device. Set 0 to disable.",
    )
    parser.add_argument(
        "--telemetry-interval",
        type=int,
        default=0,
        help="Seconds between telemetry upload writes per device. Set 0 to disable.",
    )
    parser.add_argument("--open-timeout", type=int, default=20)
    parser.add_argument("--ping-interval", type=int, default=20)
    parser.add_argument("--ping-timeout", type=int, default=20)
    parser.add_argument("--insecure", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def participant(handle: str, prefix: str) -> dict[str, str]:
    return {
        "label": prefix,
        "handle": handle,
        "device_id": f"{prefix}-{uuid.uuid4()}",
    }


def websocket_url(base_url: str, device_id: str) -> str:
    ws_base = base_url.replace("https://", "wss://").replace("http://", "ws://").rstrip("/")
    return f"{ws_base}/v1/ws?deviceId={urllib.parse.quote(device_id)}"


def websocket_ssl_context(base_url: str, insecure: bool) -> ssl.SSLContext | None:
    websocket_scheme = urllib.parse.urlparse(base_url.replace("https://", "wss://").replace("http://", "ws://")).scheme
    if websocket_scheme != "wss":
        return None
    return ssl._create_unverified_context() if insecure else ssl.create_default_context()


async def connect_websocket(
    *,
    base_url: str,
    handle: str,
    device_id: str,
    insecure: bool,
    open_timeout: int,
    ping_interval: int,
    ping_timeout: int,
) -> tuple[Any, dict[str, Any], int, int]:
    headers = {
        "x-turbo-user-handle": handle,
        "Authorization": f"Bearer {handle}",
    }
    ssl_context = websocket_ssl_context(base_url, insecure)
    url = websocket_url(base_url, device_id)
    connect_started = time.perf_counter()
    ws = await websockets.connect(
        url,
        additional_headers=headers,
        open_timeout=open_timeout,
        ping_interval=ping_interval,
        ping_timeout=ping_timeout,
        ssl=ssl_context,
    )
    connect_ms = int((time.perf_counter() - connect_started) * 1000)
    ack_started = time.perf_counter()
    raw_ack = await asyncio.wait_for(ws.recv(), timeout=10)
    ack_ms = int((time.perf_counter() - ack_started) * 1000)
    ack_payload = json.loads(raw_ack)
    if ack_payload.get("status") != "connected":
        raise RuntimeError(f"unexpected websocket ack for {handle}: {ack_payload}")
    if ack_payload.get("deviceId") != device_id:
        raise RuntimeError(f"websocket ack targeted wrong device for {handle}: {ack_payload}")
    return ws, ack_payload, connect_ms, ack_ms


def record_event(summary: ConnectionSummary, *, participant: str, kind: str, detail: str, payload: dict[str, Any] | None = None) -> None:
    summary.events.append(
        ProbeEvent(
            timestamp=time.time(),
            participant=participant,
            kind=kind,
            detail=detail,
            payload=payload,
        )
    )


async def monitor_websocket(
    *,
    ws: Any,
    summary: ConnectionSummary,
    stop_event: asyncio.Event,
    connected_started: float,
) -> None:
    while not stop_event.is_set():
        try:
            raw_message = await asyncio.wait_for(ws.recv(), timeout=1)
        except TimeoutError:
            continue
        except websockets.ConnectionClosed as exc:
            summary.closedUnexpectedly = True
            summary.closeCode = exc.code
            summary.closeReason = exc.reason
            summary.connectedDurationMs = int((time.perf_counter() - connected_started) * 1000)
            record_event(
                summary,
                participant=summary.participant,
                kind="connection-closed",
                detail=f"websocket closed unexpectedly code={exc.code} reason={exc.reason}",
            )
            stop_event.set()
            return

        summary.messagesObserved += 1
        detail = raw_message if isinstance(raw_message, str) else repr(raw_message)
        payload: dict[str, Any] | None = None
        if isinstance(raw_message, str):
            try:
                parsed = json.loads(raw_message)
            except json.JSONDecodeError:
                parsed = None
            if isinstance(parsed, dict):
                payload = parsed
                if parsed.get("message"):
                    summary.noticesObserved += 1
        record_event(
            summary,
            participant=summary.participant,
            kind="message",
            detail=detail[:240],
            payload=payload,
        )


async def repeat_http_action(
    *,
    base_url: str,
    current: dict[str, str],
    insecure: bool,
    interval_seconds: int,
    stop_event: asyncio.Event,
    results: list[HTTPActionResult],
    action_name: str,
    build_body,
    path: str,
) -> None:
    if interval_seconds <= 0:
        return
    iteration = 0
    while not stop_event.is_set():
        await asyncio.sleep(interval_seconds)
        if stop_event.is_set():
            return
        iteration += 1
        started = time.perf_counter()
        try:
            payload = await asyncio.to_thread(
                request,
                base_url,
                path,
                current["handle"],
                method="POST",
                body=build_body(current, iteration),
                insecure=insecure,
            )
            duration_ms = int((time.perf_counter() - started) * 1000)
            detail = "ok"
            if action_name == "heartbeat":
                expected_device_id = current["device_id"]
                actual_device_id = payload.get("deviceId")
                if actual_device_id != expected_device_id:
                    raise RuntimeError(
                        f"heartbeat deviceId mismatch for {current['handle']}: expected {expected_device_id}, got {actual_device_id}"
                    )
            if action_name == "telemetry":
                status = payload.get("status")
                if not status:
                    raise RuntimeError(f"telemetry response missing status: {payload}")
            results.append(
                HTTPActionResult(
                    participant=current["label"],
                    action=action_name,
                    iteration=iteration,
                    ok=True,
                    durationMs=duration_ms,
                    detail=detail,
                )
            )
        except Exception as exc:  # pragma: no cover - operational path
            duration_ms = int((time.perf_counter() - started) * 1000)
            results.append(
                HTTPActionResult(
                    participant=current["label"],
                    action=action_name,
                    iteration=iteration,
                    ok=False,
                    durationMs=duration_ms,
                    detail=str(exc),
                )
            )
            stop_event.set()
            return


def summarize_http_results(results: list[HTTPActionResult]) -> dict[str, dict[str, Any]]:
    summary: dict[str, list[HTTPActionResult]] = {}
    for result in results:
        key = f"{result.participant}:{result.action}"
        summary.setdefault(key, []).append(result)
    payload: dict[str, dict[str, Any]] = {}
    for key, grouped in summary.items():
        durations = [item.durationMs for item in grouped]
        failures = [item for item in grouped if not item.ok]
        payload[key] = {
            "total": len(grouped),
            "ok": len(grouped) - len(failures),
            "failed": len(failures),
            "minMs": min(durations),
            "medianMs": sorted(durations)[len(durations) // 2],
            "maxMs": max(durations),
            "lastFailure": failures[-1].detail if failures else None,
        }
    return payload


async def main_async(args: argparse.Namespace) -> int:
    caller = participant(args.caller, "ws-probe-caller")
    callee = participant(args.callee, "ws-probe-callee")
    participants = [caller, callee]

    for current in participants:
        request(
            args.base_url,
            "/v1/auth/session",
            current["handle"],
            method="POST",
            body={"deviceId": current["device_id"], "deviceLabel": current["device_id"]},
            insecure=args.insecure,
        )
        request(
            args.base_url,
            "/v1/devices/register",
            current["handle"],
            method="POST",
            body={"deviceId": current["device_id"], "deviceLabel": current["device_id"]},
            insecure=args.insecure,
        )
        request(
            args.base_url,
            "/v1/presence/heartbeat",
            current["handle"],
            method="POST",
            body={"deviceId": current["device_id"]},
            insecure=args.insecure,
        )

    caller_ws, caller_ack, caller_connect_ms, caller_ack_ms = await connect_websocket(
        base_url=args.base_url,
        handle=caller["handle"],
        device_id=caller["device_id"],
        insecure=args.insecure,
        open_timeout=args.open_timeout,
        ping_interval=args.ping_interval,
        ping_timeout=args.ping_timeout,
    )
    callee_ws, callee_ack, callee_connect_ms, callee_ack_ms = await connect_websocket(
        base_url=args.base_url,
        handle=callee["handle"],
        device_id=callee["device_id"],
        insecure=args.insecure,
        open_timeout=args.open_timeout,
        ping_interval=args.ping_interval,
        ping_timeout=args.ping_timeout,
    )

    caller_summary = ConnectionSummary(
        participant=caller["label"],
        handle=caller["handle"],
        deviceId=caller["device_id"],
        connectMs=caller_connect_ms,
        ackMs=caller_ack_ms,
        ackPayload=caller_ack,
    )
    callee_summary = ConnectionSummary(
        participant=callee["label"],
        handle=callee["handle"],
        deviceId=callee["device_id"],
        connectMs=callee_connect_ms,
        ackMs=callee_ack_ms,
        ackPayload=callee_ack,
    )
    connected_started = time.perf_counter()
    stop_event = asyncio.Event()
    http_results: list[HTTPActionResult] = []

    tasks = [
        asyncio.create_task(
            monitor_websocket(
                ws=caller_ws,
                summary=caller_summary,
                stop_event=stop_event,
                connected_started=connected_started,
            )
        ),
        asyncio.create_task(
            monitor_websocket(
                ws=callee_ws,
                summary=callee_summary,
                stop_event=stop_event,
                connected_started=connected_started,
            )
        ),
        asyncio.create_task(
            repeat_http_action(
                base_url=args.base_url,
                current=caller,
                insecure=args.insecure,
                interval_seconds=args.heartbeat_interval,
                stop_event=stop_event,
                results=http_results,
                action_name="heartbeat",
                build_body=lambda current, _iteration: {"deviceId": current["device_id"]},
                path="/v1/presence/heartbeat",
            )
        ),
        asyncio.create_task(
            repeat_http_action(
                base_url=args.base_url,
                current=callee,
                insecure=args.insecure,
                interval_seconds=args.heartbeat_interval,
                stop_event=stop_event,
                results=http_results,
                action_name="heartbeat",
                build_body=lambda current, _iteration: {"deviceId": current["device_id"]},
                path="/v1/presence/heartbeat",
            )
        ),
    ]

    if args.telemetry_interval > 0:
        for current in participants:
            tasks.append(
                asyncio.create_task(
                    repeat_http_action(
                        base_url=args.base_url,
                        current=current,
                        insecure=args.insecure,
                        interval_seconds=args.telemetry_interval,
                        stop_event=stop_event,
                        results=http_results,
                        action_name="telemetry",
                        build_body=lambda current, iteration: {
                            "eventName": "websocket.stability.probe",
                            "source": "probe",
                            "severity": "info",
                            "userHandle": current["handle"],
                            "deviceId": current["device_id"],
                            "appVersion": f"websocket-stability-probe:{iteration}",
                            "phase": "probe",
                            "reason": "websocket-stability",
                            "message": "websocket stability probe",
                            "metadataText": json.dumps({"participant": current["label"], "iteration": str(iteration)}),
                            "devTraffic": "true",
                            "alert": "false",
                        },
                        path="/v1/telemetry/events",
                    )
                )
            )

    try:
        await asyncio.wait_for(stop_event.wait(), timeout=args.duration)
    except TimeoutError:
        pass
    finally:
        stop_event.set()
        caller_summary.connectedDurationMs = caller_summary.connectedDurationMs or int((time.perf_counter() - connected_started) * 1000)
        callee_summary.connectedDurationMs = callee_summary.connectedDurationMs or int((time.perf_counter() - connected_started) * 1000)
        for task in tasks:
            task.cancel()
        for ws in (caller_ws, callee_ws):
            with contextlib.suppress(Exception):
                await ws.close()
        with contextlib.suppress(Exception):
            await asyncio.gather(*tasks, return_exceptions=True)

    failed_http = [result for result in http_results if not result.ok]
    unexpected_closures = [summary for summary in (caller_summary, callee_summary) if summary.closedUnexpectedly]

    payload = {
        "baseUrl": args.base_url,
        "durationSeconds": args.duration,
        "heartbeatIntervalSeconds": args.heartbeat_interval,
        "telemetryIntervalSeconds": args.telemetry_interval,
        "caller": asdict(caller_summary),
        "callee": asdict(callee_summary),
        "httpSummary": summarize_http_results(http_results),
        "httpResults": [asdict(result) for result in http_results],
    }

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        for summary in (caller_summary, callee_summary):
            state = "closed-unexpectedly" if summary.closedUnexpectedly else "held-open"
            close_suffix = (
                ""
                if not summary.closedUnexpectedly
                else f" closeCode={summary.closeCode} closeReason={summary.closeReason or 'none'}"
            )
            print(
                f"{summary.participant} handle={summary.handle} deviceId={summary.deviceId} "
                f"connectMs={summary.connectMs} ackMs={summary.ackMs} "
                f"connectedDurationMs={summary.connectedDurationMs} state={state} "
                f"messages={summary.messagesObserved} notices={summary.noticesObserved}{close_suffix}"
            )
        if http_results:
            print("\nhttp summary")
            print(json.dumps(payload["httpSummary"], indent=2, sort_keys=True))

    return 1 if unexpected_closures or failed_http else 0


def main() -> int:
    args = parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    raise SystemExit(main())
