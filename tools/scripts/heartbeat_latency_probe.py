#!/usr/bin/env python3
#
# Minimal tail-latency probe for Turbo's heartbeat endpoint.
#
# Endpoint:
#   POST /v1/presence/heartbeat
#   Headers:
#     x-turbo-user-handle: @avery
#     Authorization: Bearer @avery
#   Body:
#     {"deviceId":"heartbeat-latency-probe-..."}
#
# Current Unison implementation under bb/main, narrowed to the route and
# storage call that matter for heartbeat latency:
#
# turbo.service.presence.heartbeat : Database -> '{Route, Config, Exception, Http, Storage, Remote, Random} ()
# turbo.service.presence.heartbeat db = do
#   use Parser /
#   use object empty
#   noCapture POST (s "v1" / s "presence" / s "heartbeat")
#   match requireUser db () with
#     Left err          -> unauthorized.json (empty |> addText "error" err)
#     Right currentUser ->
#       currentUserId =
#         (User userId _ _ _ _) = currentUser
#         userId
#       fields = decodeJson (Decoder.object Decoder.text)
#       match Map.get "deviceId" fields with
#         None              -> badRequest.json (empty |> addText "error" "missing deviceId")
#         Some deviceIdText ->
#           deviceId = DeviceId.fromText deviceIdText
#           _ = store.presence.heartbeat db deviceId currentUserId ()
#           _ = touchCurrent db deviceId ()
#           ok.json (empty |> addText "deviceId" deviceIdText |> addText "userId" (UserId.toText currentUserId) |> addText "status" "online")
#
# turbo.store.presence.heartbeat : Database -> DeviceId -> UserId -> '{Exception, Storage, Remote, Random} DevicePresence
# turbo.store.presence.heartbeat db deviceId userId = do
#   now = now!
#   match presence.get db deviceId () with
#     Some existing@(DevicePresence _ _ _ currentChannelId _) ->
#       if presence.internal.shouldWriteHeartbeat now userId existing then
#         presence.upsert db deviceId userId DevicePresenceStatus.Online currentChannelId ()
#       else existing
#     None ->
#       presence.upsert db deviceId userId DevicePresenceStatus.Online None ()

import json
import statistics
import subprocess
import time

BASE_URL = "https://staging.beepbeep.to"
HANDLE = "@avery"
ITERATIONS = 30
TIMEOUT_SECONDS = 8
SLOW_MS = 2000


def main() -> None:
    durations = []
    failures = 0
    url = BASE_URL.rstrip("/") + "/v1/presence/heartbeat"

    for i in range(1, ITERATIONS + 1):
        device_id = f"heartbeat-latency-probe-{int(time.time())}-{i}"
        body = json.dumps({"deviceId": device_id})
        cmd = [
            "curl", "-sS", "--max-time", str(TIMEOUT_SECONDS),
            "-w", "\n%{http_code} %{time_total}\n",
            "-X", "POST",
            "-H", f"x-turbo-user-handle: {HANDLE}",
            "-H", f"Authorization: Bearer {HANDLE}",
            "-H", "Content-Type: application/json",
            "--data-binary", body,
            url,
        ]
        p = subprocess.run(cmd, text=True, capture_output=True)
        stdout = p.stdout.strip()
        if "\n" not in stdout:
            failures += 1
            print(f"{i:02d} http=000 ms={TIMEOUT_SECONDS * 1000:.0f} FAIL {p.stderr.strip()}")
            durations.append(int(TIMEOUT_SECONDS * 1000))
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

        print(f"{i:02d} http={http_code} ms={ms} {'SLOW' if ms >= SLOW_MS else ''}")

    slow = [ms for ms in durations if ms >= SLOW_MS]
    print("\nsummary")
    print(f"failures={failures}")
    print(f"min={min(durations)}ms median={int(statistics.median(durations))}ms max={max(durations)}ms")
    print(f"slow>={SLOW_MS}ms count={len(slow)} values={slow}")


if __name__ == "__main__":
    main()
