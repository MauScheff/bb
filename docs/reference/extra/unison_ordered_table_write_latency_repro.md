# OrderedTable Write Latency Repro

```unison
storageLatencyRepro.table : Database -> OrderedTable Text Text
storageLatencyRepro.table db =
  OrderedTable.named db "storageLatencyReproByDevice_v1" Universal.ordering

storageLatencyRepro.service : Database -> '{Route, Exception, Storage, Remote} ()
storageLatencyRepro.service db = do
  use Parser /
  use object empty
  noCapture POST (s "write")
  fields = decodeJson (Decoder.object Decoder.text)
  match Map.get "deviceId" fields with
    None -> badRequest.json (empty |> addText "error" "missing deviceId")
    Some deviceId ->
      _ = OrderedTable.write (storageLatencyRepro.table db) deviceId deviceId
      ok.json (empty |> addText "deviceId" deviceId |> addText "status" "stored")

storageLatencyRepro.deploy : '{IO, Exception} URI
storageLatencyRepro.deploy = Cloud.main do
  env = Environment.named "storage-latency-repro-v1"
  db = Database.named "storage-latency-repro-v1"
  Database.assign db env
  serviceHash = Route.deploy env (storageLatencyRepro.service db)
  serviceName = ServiceName.named "storage-latency-repro-v1"
  _ = catch do ServiceName.unassign serviceName
  ServiceName.assign serviceName serviceHash
```

```python
#!/usr/bin/env python3

import json
import statistics
import subprocess
import time

BASE_URL = "https://YOUR-HANDLE.unison-services.cloud/s/storage-latency-repro-v1"
ITERATIONS = 60
TIMEOUT_SECONDS = 8
SLOW_MS = 2000

durations = []
failures = 0
url = BASE_URL.rstrip("/") + "/write"

for i in range(1, ITERATIONS + 1):
    device_id = f"storage-latency-repro-{int(time.time())}-{i}"
    p = subprocess.run(
        [
            "curl", "-sS", "--max-time", str(TIMEOUT_SECONDS),
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
        durations.append(int(TIMEOUT_SECONDS * 1000))
        print(f"{i:02d} http=000 ms={TIMEOUT_SECONDS * 1000:.0f} FAIL {p.stderr.strip()}")
        continue

    response, metrics = stdout.rsplit("\n", 1)
    http_code, seconds = metrics.split()
    ms = int(float(seconds) * 1000)
    durations.append(ms)

    ok = p.returncode == 0 and http_code.startswith("2")
    try:
        parsed = json.loads(response)
        ok = ok and parsed.get("deviceId") == device_id and parsed.get("status") == "stored"
    except json.JSONDecodeError:
        ok = False

    failures += 0 if ok else 1
    print(f"{i:02d} http={http_code} ms={ms} {'SLOW' if ms >= SLOW_MS else ''}")

slow = [ms for ms in durations if ms >= SLOW_MS]
print("\nsummary")
print(f"failures={failures}")
print(f"min={min(durations)}ms median={int(statistics.median(durations))}ms max={max(durations)}ms")
print(f"slow>={SLOW_MS}ms count={len(slow)} values={slow}")
```
