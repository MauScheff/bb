#!/usr/bin/env python3

import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request


DEFAULT_DATASET = os.environ.get("TURBO_TELEMETRY_DATASET", "turbo_telemetry_events_v1")
DEFAULT_ACCOUNT_ID = os.environ.get("TURBO_CLOUDFLARE_ACCOUNT_ID", "").strip()
DEFAULT_API_TOKEN = os.environ.get("TURBO_CLOUDFLARE_ANALYTICS_READ_TOKEN", "").strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Query Turbo telemetry from Cloudflare Analytics Engine.")
    parser.add_argument("--account-id", default=DEFAULT_ACCOUNT_ID)
    parser.add_argument("--api-token", default=DEFAULT_API_TOKEN)
    parser.add_argument("--dataset", default=DEFAULT_DATASET)
    parser.add_argument("--query", help="Raw SQL query. If omitted, a recent-events query is generated.")
    parser.add_argument("--hours", type=int, default=24)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--source")
    parser.add_argument("--severity")
    parser.add_argument("--event-name")
    parser.add_argument("--exclude-event-name")
    parser.add_argument("--dev-traffic", choices=["true", "false"])
    parser.add_argument("--user-handle")
    parser.add_argument("--device-id")
    parser.add_argument("--channel-id")
    parser.add_argument("--invariant-id")
    parser.add_argument("--follow", action="store_true", help="Poll and print new matching events as they arrive.")
    parser.add_argument("--poll-seconds", type=int, default=5)
    parser.add_argument("--json", action="store_true", help="Print the raw response JSON.")
    parser.add_argument("--insecure", action="store_true", help="Disable TLS certificate verification for development tooling.")
    return parser.parse_args()


def sql_string(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def build_recent_query(args: argparse.Namespace) -> str:
    filters = [f"timestamp > NOW() - INTERVAL '{args.hours}' HOUR"]
    optional_filters = {
        "blob1": args.event_name,
        "blob2": args.source,
        "blob3": args.severity,
        "blob5": args.user_handle,
        "blob6": args.device_id,
        "blob8": args.channel_id,
        "blob14": args.invariant_id,
        "blob19": args.dev_traffic,
    }
    for field, value in optional_filters.items():
        if value:
            filters.append(f"{field} = {sql_string(value)}")
    if args.exclude_event_name:
        filters.append(f"blob1 != {sql_string(args.exclude_event_name)}")

    where_clause = " AND ".join(filters)
    return f"""
SELECT
  timestamp,
  blob1 AS event_name,
  blob2 AS source,
  blob3 AS severity,
  blob4 AS user_id,
  blob5 AS user_handle,
  blob6 AS device_id,
  blob7 AS session_id,
  blob8 AS channel_id,
  blob9 AS peer_user_id,
  blob10 AS peer_device_id,
  blob11 AS peer_handle,
  blob12 AS app_version,
  blob13 AS backend_version,
  blob14 AS invariant_id,
  blob15 AS phase,
  blob16 AS reason,
  blob17 AS message,
  blob18 AS metadata_text,
  blob19 AS dev_traffic,
  double2 AS alert_flag,
  double3 AS severity_rank
FROM {args.dataset}
WHERE {where_clause}
ORDER BY timestamp DESC
LIMIT {args.limit}
""".strip()


def execute_query(account_id: str, api_token: str, query: str, insecure: bool = False) -> dict:
    if not account_id:
        raise SystemExit("Missing --account-id or TURBO_CLOUDFLARE_ACCOUNT_ID")
    if not api_token:
        raise SystemExit("Missing --api-token or TURBO_CLOUDFLARE_ANALYTICS_READ_TOKEN")

    url = f"https://api.cloudflare.com/client/v4/accounts/{account_id}/analytics_engine/sql"
    request = urllib.request.Request(
        url,
        method="POST",
        headers={"Authorization": f"Bearer {api_token}"},
        data=query.encode("utf-8"),
    )
    context = ssl._create_unverified_context() if insecure else None
    try:
        with urllib.request.urlopen(request, context=context, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Cloudflare SQL API request failed: {exc.code} {body}") from exc


def print_pretty(response: dict, query: str) -> None:
    print(query)
    print()
    data = response.get("data")
    if not isinstance(data, list):
        print(json.dumps(response, indent=2, sort_keys=True))
        return
    if not data:
        print("<no rows>")
        return

    for row in data:
        if not isinstance(row, dict):
            print(json.dumps(row, indent=2, sort_keys=True))
            continue
        parts = [
            row.get("timestamp", "?"),
            row.get("severity", "unknown"),
            row.get("source", "unknown"),
            row.get("event_name", "unknown"),
        ]
        identity = row.get("user_handle") or row.get("user_id") or row.get("device_id") or "unknown"
        message = row.get("message") or row.get("reason") or row.get("invariant_id") or ""
        print(" | ".join(parts))
        print(
            f"  actor={identity} channel={row.get('channel_id') or 'none'} "
            f"alert={row.get('alert_flag')} dev={row.get('dev_traffic') or 'false'}"
        )
        if message:
            print(f"  {message}")
        metadata = row.get("metadata_text")
        if metadata:
            print(f"  metadata={metadata}")
        print()


def print_pretty_rows(rows: list[dict]) -> None:
    for row in rows:
        parts = [
            row.get("timestamp", "?"),
            row.get("severity", "unknown"),
            row.get("source", "unknown"),
            row.get("event_name", "unknown"),
        ]
        identity = row.get("user_handle") or row.get("user_id") or row.get("device_id") or "unknown"
        message = row.get("message") or row.get("reason") or row.get("invariant_id") or ""
        print(" | ".join(parts))
        print(
            f"  actor={identity} channel={row.get('channel_id') or 'none'} "
            f"alert={row.get('alert_flag')} dev={row.get('dev_traffic') or 'false'}"
        )
        if message:
            print(f"  {message}")
        metadata = row.get("metadata_text")
        if metadata:
            print(f"  metadata={metadata}")
        print()


def row_key(row: dict) -> str:
    return json.dumps(row, sort_keys=True, separators=(",", ":"))


def follow_pretty(account_id: str, api_token: str, query: str, poll_seconds: int, insecure: bool) -> None:
    print(query)
    print()
    seen: set[str] = set()
    try:
        while True:
            response = execute_query(account_id, api_token, query, insecure=insecure)
            data = response.get("data")
            rows = [row for row in data if isinstance(row, dict)] if isinstance(data, list) else []
            fresh_rows: list[dict] = []
            for row in reversed(rows):
                key = row_key(row)
                if key in seen:
                    continue
                seen.add(key)
                fresh_rows.append(row)
            if fresh_rows:
                print_pretty_rows(fresh_rows)
                sys.stdout.flush()
            time.sleep(poll_seconds)
    except KeyboardInterrupt:
        return


def main() -> None:
    args = parse_args()
    if args.follow and args.json:
        raise SystemExit("--follow and --json cannot be combined")
    query = args.query or build_recent_query(args)
    if args.follow:
        follow_pretty(args.account_id, args.api_token, query, args.poll_seconds, args.insecure)
        return
    response = execute_query(args.account_id, args.api_token, query, insecure=args.insecure)
    if args.json:
        json.dump(response, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return
    print_pretty(response, query)


if __name__ == "__main__":
    main()
