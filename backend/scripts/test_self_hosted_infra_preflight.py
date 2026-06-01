#!/usr/bin/env python3

from __future__ import annotations

import socketserver
import sys
import threading
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import self_hosted_infra_preflight


class SelfHostedInfraPreflightTests(unittest.TestCase):
    def test_postgres_protocol_accepts_ssl_request_response(self) -> None:
        with SingleResponseServer(b"N") as server:
            result = self_hosted_infra_preflight.check_postgres_protocol(
                "postgres-protocol", server.host, server.port
            )

        self.assertTrue(result["ok"])
        self.assertEqual(result["response"], "N")

    def test_postgres_protocol_rejects_unrelated_tcp_service(self) -> None:
        with SingleResponseServer(b"HTTP/1.1 200 OK\r\n") as server:
            result = self_hosted_infra_preflight.check_postgres_protocol(
                "postgres-protocol", server.host, server.port
            )

        self.assertFalse(result["ok"])

    def test_redis_protocol_accepts_pong(self) -> None:
        with SingleResponseServer(b"+PONG\r\n") as server:
            result = self_hosted_infra_preflight.check_redis_protocol(
                "redis-protocol", server.host, server.port
            )

        self.assertTrue(result["ok"])
        self.assertIn("PONG", result["responsePreview"])

    def test_redis_protocol_rejects_unrelated_tcp_service(self) -> None:
        with SingleResponseServer(b"not redis") as server:
            result = self_hosted_infra_preflight.check_redis_protocol(
                "redis-protocol", server.host, server.port
            )

        self.assertFalse(result["ok"])

    def test_run_command_reports_timeout(self) -> None:
        result = self_hosted_infra_preflight.run_command(
            "slow-command",
            [sys.executable, "-c", "import time; time.sleep(2)"],
            timeout=0.1,
        )

        self.assertFalse(result["ok"])
        self.assertTrue(result["timedOut"])
        self.assertEqual(result["exitCode"], None)
        self.assertEqual(result["timeoutSeconds"], 0.1)

    def test_docker_socket_accepts_ping_response(self) -> None:
        response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"

        with mock.patch("self_hosted_infra_preflight.socket.socket") as socket_factory:
            connection = socket_factory.return_value.__enter__.return_value
            connection.recv.return_value = response

            result = self_hosted_infra_preflight.check_docker_socket(
                "docker-daemon-socket", "/tmp/docker.sock"
            )

        self.assertTrue(result["ok"])
        self.assertEqual(result["socket"], "/tmp/docker.sock")
        connection.connect.assert_called_once_with("/tmp/docker.sock")


class SingleResponseServer:
    def __init__(self, response: bytes) -> None:
        self.response = response
        self.server = socketserver.TCPServer(("127.0.0.1", 0), self._handler())
        self.host, self.port = self.server.server_address
        self.thread = threading.Thread(target=self.server.serve_forever)

    def __enter__(self) -> "SingleResponseServer":
        self.thread.start()
        return self

    def __exit__(self, *args: object) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()

    def _handler(self) -> type[socketserver.BaseRequestHandler]:
        response = self.response

        class Handler(socketserver.BaseRequestHandler):
            def handle(self) -> None:
                _ = self.request.recv(128)
                self.request.sendall(response)

        return Handler


if __name__ == "__main__":
    unittest.main()
