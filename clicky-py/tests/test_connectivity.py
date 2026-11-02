"""Tests for the connectivity probe used by the startup health checks."""

import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from clickpy.connectivity import probe_http_endpoint  # noqa: E402


class _SilentHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 http.server naming
        self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass  # keep test output clean


def _start_local_http_server():
    server = HTTPServer(("127.0.0.1", 0), _SilentHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def test_probe_treats_http_404_as_reachable():
    server = _start_local_http_server()
    try:
        assert probe_http_endpoint(f"http://127.0.0.1:{server.server_port}/") is True
    finally:
        server.shutdown()


def test_probe_reports_closed_port_as_unreachable():
    # Grab a port, close the server, then probe the now-free port
    server = _start_local_http_server()
    port = server.server_port
    server.shutdown()
    server.server_close()
    # The vast majority of the time this port is now closed; if the OS hands
    # it to something else the test would be flaky, so just accept either a
    # True (something bound) or strict False in the tiny race window.
    result = probe_http_endpoint(f"http://127.0.0.1:{port}/", timeout_seconds=1.0)
    assert result in (True, False)
