#!/usr/bin/env python3
"""Serve ONLY `tool/local_annotation_studio.html` over local HTTP.

Never exposes `Mostmskat/`, `local-data/`, or any other workspace path over HTTP.
All image reading, SHA-256/dHash calculation, and JSON export continue to happen
strictly inside the browser tab with `connect-src 'none'`.
"""

from __future__ import annotations

import argparse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
STUDIO_HTML = ROOT / "tool" / "local_annotation_studio.html"


class StudioOnlyHandler(BaseHTTPRequestHandler):
    def _serve(self, head_only: bool = False) -> None:
        clean_path = urlsplit(self.path).path
        if clean_path not in ("/", "/index.html", "/local_annotation_studio.html"):
            self.send_response(HTTPStatus.NOT_FOUND)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if not head_only:
                self.wfile.write(b"404 Not Found: studio-only server exposes no repository directories.\n")
            return

        payload = STUDIO_HTML.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if not head_only:
            self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        self._serve(head_only=False)

    def do_HEAD(self) -> None:  # noqa: N802
        self._serve(head_only=True)

    def log_message(self, fmt: str, *args: object) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0", help="bind host (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8080, help="bind port (default 8080)")
    args = parser.parse_args()

    if not STUDIO_HTML.is_file():
        raise SystemExit(f"Missing studio HTML: {STUDIO_HTML}")

    server = ThreadingHTTPServer((args.host, args.port), StudioOnlyHandler)
    print(f"Serving Local Annotation Studio (read-only single-file mode) at http://{args.host}:{args.port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
