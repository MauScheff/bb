#!/usr/bin/env python3
#
# Minimal probe for an isolated Unison Cloud service, not BeepBeep/Turbo.
#
# Deployed URL:
#   https://mauscheff.unison-services.cloud/s/turbo-heartbeat-latency-probe-v1/
#
# Endpoint:
#   POST /heartbeat
#   POST /heartbeat-fork
#   POST /heartbeat-local-fork
#   POST /heartbeat-storage
#   Body:
#     {"deviceId":"isolated-heartbeat-latency-probe-..."}
#
# Complete Unison service:
#
# turbo.probes.heartbeatLatency.service : '{Route, Exception} ()
# turbo.probes.heartbeatLatency.pureRoute = do
#   use Parser /
#   use object empty
#   noCapture POST (s "heartbeat")
#   fields = decodeJson (Decoder.object Decoder.text)
#   match Map.get "deviceId" fields with
#     None              -> badRequest.json (empty |> addText "error" "missing deviceId")
#     Some deviceIdText -> ok.json (empty |> addText "deviceId" deviceIdText |> addText "status" "online")
#
# turbo.probes.heartbeatLatency.forkRoute = do
#   use Parser /
#   use object empty
#   noCapture POST (s "heartbeat-fork")
#   fields = decodeJson (Decoder.object Decoder.text)
#   match Map.get "deviceId" fields with
#     None              -> badRequest.json (empty |> addText "error" "missing deviceId")
#     Some deviceIdText ->
#       _ = forkAt pool() do
#         toRemote do ()
#       ok.json (empty |> addText "deviceId" deviceIdText |> addText "status" "online")
#
# turbo.probes.heartbeatLatency.localForkRoute = do
#   use Parser /
#   use object empty
#   noCapture POST (s "heartbeat-local-fork")
#   fields = decodeJson (Decoder.object Decoder.text)
#   match Map.get "deviceId" fields with
#     None              -> badRequest.json (empty |> addText "error" "missing deviceId")
#     Some deviceIdText ->
#       _ = Remote.fork pool() do
#         toRemote do ()
#       ok.json (empty |> addText "deviceId" deviceIdText |> addText "status" "online")
#
# turbo.probes.heartbeatLatency.table : Database -> OrderedTable Text Text
# turbo.probes.heartbeatLatency.table db =
#   OrderedTable.named db "isolatedHeartbeatLatencyByDevice_v1" Universal.ordering
#
# turbo.probes.heartbeatLatency.storageRoute : Database -> '{Route, Exception, Storage, Remote} ()
# turbo.probes.heartbeatLatency.storageRoute db = do
#   use Parser /
#   use object empty
#   noCapture POST (s "heartbeat-storage")
#   fields = decodeJson (Decoder.object Decoder.text)
#   match Map.get "deviceId" fields with
#     None              -> badRequest.json (empty |> addText "error" "missing deviceId")
#     Some deviceIdText ->
#       _ = OrderedTable.write (heartbeatLatency.table db) deviceIdText deviceIdText
#       ok.json (empty |> addText "deviceId" deviceIdText |> addText "status" "online")
#
# turbo.probes.heartbeatLatency.service =
#   Route.or heartbeatLatency.pureRoute
#     (Route.or heartbeatLatency.forkRoute
#       (Route.or heartbeatLatency.localForkRoute (heartbeatLatency.storageRoute db)))
#
# turbo.probes.heartbeatLatency.deploy : '{IO, Exception} URI
# turbo.probes.heartbeatLatency.deploy = Cloud.main do
#   env = Environment.named "turbo-heartbeat-latency-probe-v1"
#   db = Database.named "turbo-heartbeat-latency-probe-v1"
#   Database.assign db env
#   serviceHash = Route.deploy env (heartbeatLatency.service db)
#   serviceName = ServiceName.named "turbo-heartbeat-latency-probe-v1"
#   _ = catch do ServiceName.unassign serviceName
#   ServiceName.assign serviceName serviceHash

import json
import statistics
import subprocess
import time
import argparse

BASE_URL = "https://mauscheff.unison-services.cloud/s/turbo-heartbeat-latency-probe-v1"
ENDPOINT_PATH = "heartbeat-storage"
ITERATIONS = 30
TIMEOUT_SECONDS = 12
SLOW_MS = 2000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Probe isolated Unison Cloud request latency. Each iteration is one "
            "separate HTTP request; heartbeat-storage performs one OrderedTable.write."
        )
    )
    parser.add_argument("--base-url", default=BASE_URL)
    parser.add_argument(
        "--endpoint",
        default=ENDPOINT_PATH,
        choices=[
            "heartbeat",
            "heartbeat-fork",
            "heartbeat-local-fork",
            "heartbeat-storage",
        ],
    )
    parser.add_argument("--iterations", type=int, default=ITERATIONS)
    parser.add_argument("--timeout", type=float, default=TIMEOUT_SECONDS)
    parser.add_argument("--slow-ms", type=int, default=SLOW_MS)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    durations = []
    failures = 0
    url = args.base_url.rstrip("/") + "/" + args.endpoint.lstrip("/")

    print(f"baseUrl={args.base_url}")
    print(f"endpoint={args.endpoint}")
    print(f"iterations={args.iterations}")
    print(f"timeoutSeconds={args.timeout}")
    print(f"slowMs={args.slow_ms}")
    print()

    for i in range(1, args.iterations + 1):
        device_id = f"isolated-heartbeat-latency-probe-{int(time.time())}-{i}"
        p = subprocess.run(
            [
                "curl", "-sS", "--max-time", str(args.timeout),
                "-w", "\n%{http_code} %{time_total}\n",
                "-X", "POST",
                "-H", "Content-Type: application/json",
                "--data-binary", json.dumps({"deviceId": device_id}),
                url,
            ],
            text=True,
            capture_output=True,
        )

        stdout = p.stdout.strip()
        if "\n" not in stdout:
            failures += 1
            durations.append(int(args.timeout * 1000))
            print(f"{i:02d} http=000 ms={args.timeout * 1000:.0f} FAIL {p.stderr.strip()}")
            continue

        response, metrics = stdout.rsplit("\n", 1)
        http_code, seconds = metrics.split()
        ms = int(float(seconds) * 1000)
        durations.append(ms)

        ok = p.returncode == 0 and http_code.startswith("2")
        try:
            parsed = json.loads(response)
            ok = ok and parsed.get("deviceId") == device_id and parsed.get("status") == "online"
        except json.JSONDecodeError:
            ok = False
        failures += 0 if ok else 1

        print(f"{i:02d} http={http_code} ms={ms} {'SLOW' if ms >= args.slow_ms else ''}")

    slow = [ms for ms in durations if ms >= args.slow_ms]
    print("\nsummary")
    print(f"failures={failures}")
    print(f"min={min(durations)}ms median={int(statistics.median(durations))}ms max={max(durations)}ms")
    print(f"slow>={args.slow_ms}ms count={len(slow)} values={slow}")


if __name__ == "__main__":
    main()
