#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import simulator_self_hosted_suite_proof


class SimulatorSelfHostedSuiteProofTests(unittest.TestCase):
    def test_health_preflight_requires_self_hosted_health_and_config(self) -> None:
        server = JsonServer(
            {
                "/s/turbo/v1/health": {"status": "ok", "runtime": "self-hosted"},
                "/s/turbo/v1/config": {
                    "mode": "self-hosted",
                    "supportsWebSocket": True,
                },
            }
        )
        with server:
            result = simulator_self_hosted_suite_proof.health_preflight(server.base_url, 1.0)

        self.assertTrue(result["ok"])
        self.assertTrue(all(check["ok"] for check in result["checks"]))

    def test_health_preflight_rejects_cloud_shaped_backend(self) -> None:
        server = JsonServer(
            {
                "/s/turbo/v1/health": {"status": "ok"},
                "/s/turbo/v1/config": {
                    "mode": "cloud",
                    "supportsWebSocket": True,
                },
            }
        )
        with server:
            result = simulator_self_hosted_suite_proof.health_preflight(server.base_url, 1.0)

        self.assertFalse(result["ok"])
        health, config = result["checks"]
        self.assertFalse(health["ok"])
        self.assertFalse(config["ok"])
        self.assertEqual(result["reason"], "self-hosted health/config preflight failed")


class JsonServer:
    def __init__(self, routes: dict[str, dict[str, object]]) -> None:
        self.routes = routes
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        host, port = self.server.server_address
        self.base_url = f"http://{host}:{port}/s/turbo"
        self.thread = threading.Thread(target=self.server.serve_forever)

    def __enter__(self) -> "JsonServer":
        self.thread.start()
        return self

    def __exit__(self, *args: object) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()

    def _handler(self) -> type[BaseHTTPRequestHandler]:
        routes = self.routes

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                body = routes.get(self.path)
                if body is None:
                    self.send_response(404)
                    self.end_headers()
                    return
                encoded = json.dumps(body).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def log_message(self, format: str, *args: object) -> None:
                return

        return Handler


if __name__ == "__main__":
    unittest.main()
