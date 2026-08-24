#!/usr/bin/env python3
"""mnml demo mock API server.

Serves canned JSON fixtures from ../fixtures/ over HTTP on
localhost:7071. Routes are matched against the on-disk fixture tree:

    GET  /jira/rest/api/2/board                → fixtures/jira/boards.json
    GET  /jira/rest/api/2/issue/NTL-142       → fixtures/jira/issues/NTL-142.json
    GET  /bitbucket/2.0/repositories/bloomlabs → fixtures/bitbucket/repos.json
    GET  /github/repos/bloomlabs/notely/pulls    → fixtures/github/pulls.json

Anything with a matching file → JSON body + 200.
Anything without → 404 + a helpful error naming the expected path.

The server is started by `mnml --demo` if it isn't already running
on 7071. Manual invocation: `python3 demo/server/server.py`.
"""
from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

PORT = 7071
ROOT = Path(__file__).resolve().parent.parent / "fixtures"


def _is_under(child: Path, parent: Path) -> bool:
    """True iff `child` (already-resolved) sits under `parent`. Used
    to reject `..`-traversal attempts before opening the file."""
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        self._handle("GET")

    def do_POST(self) -> None:
        self._handle("POST")

    def _handle(self, method: str) -> None:
        path = urlparse(self.path).path.strip("/")
        # Two lookup strategies:
        #  1. exact path → fixtures/<path>.json
        #  2. per-verb file → fixtures/<path>.<verb>.json (rare)
        candidates = [
            ROOT / f"{path}.json",
            ROOT / f"{path}.{method.lower()}.json",
            ROOT / path / "index.json",
        ]
        # Guard against `..` traversal — a request like `../../etc/hosts`
        # otherwise walks the fixture tree upward and could serve any
        # `.json` file reachable from it. Localhost-only + demo-only,
        # but leaving it unchecked is a footgun. `.resolve()` collapses
        # `..` segments so we can compare against the fixture root.
        root_resolved = ROOT.resolve()
        candidates = [c for c in candidates if _is_under(c.resolve(strict=False), root_resolved)]
        hit = next((p for p in candidates if p.is_file()), None)
        if hit is None:
            self._write(404, {
                "error": "fixture-not-found",
                "path": path,
                "tried": [str(p.relative_to(ROOT.parent)) for p in candidates],
                "hint": "Add a JSON file at one of the tried paths to mock this endpoint.",
            })
            return
        try:
            body = json.loads(hit.read_text())
        except json.JSONDecodeError as e:
            self._write(500, {"error": "fixture-invalid-json", "path": str(hit), "detail": str(e)})
            return
        self._write(200, body)

    def _write(self, status: int, body: object) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Request-Id", "req_01hp9v3qk8g4m2z8t7d5r0c1e9")
        # /api/* routes emit realistic Set-Cookie headers so the
        # Request pane's Cookies tab has something to display in
        # the http.gif demo tape. Two cookies (session + csrf)
        # gives the tab enough shape to read as "real API"
        # without leaking anything sensitive.
        path = urlparse(self.path).path
        if path.startswith("/api/"):
            self.send_header(
                "Set-Cookie",
                "session=eyJ1IjoiYXZhIn0.demo; "
                "Path=/; Domain=localhost; HttpOnly; SameSite=Lax; Max-Age=3600",
            )
            self.send_header(
                "Set-Cookie",
                "csrf=8f0d21c4a9b7e3f61d5c02af49b8; "
                "Path=/; Domain=localhost; SameSite=Strict",
            )
        self.end_headers()
        self.wfile.write(payload)

    # Suppress the noisy default access log.
    def log_message(self, fmt: str, *args) -> None:  # noqa: N802 (stdlib signature)
        pass


def main() -> int:
    server = HTTPServer(("127.0.0.1", PORT), FixtureHandler)
    print(f"mnml-demo-server on http://127.0.0.1:{PORT} (fixtures: {ROOT})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("shutdown")
    return 0


if __name__ == "__main__":
    sys.exit(main())
