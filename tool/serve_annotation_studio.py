#!/usr/bin/env python3
"""Serve ONLY `tool/local_annotation_studio.html` over local HTTP (PC or Android LAN/USB).

Never exposes `Mostmskat/`, `local-data/`, or any other workspace path over HTTP,
and rejects all non-GET/HEAD verbs (405) so nothing can be uploaded to this server.
All image reading, SHA-256/dHash calculation, draft storage, and JSON export happen
strictly inside the browser tab under `connect-src 'none'`.
"""

from __future__ import annotations

import argparse
import ipaddress
import socket
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
STUDIO_HTML = ROOT / "tool" / "local_annotation_studio.html"
STUDIO_CSP = (
    "default-src 'none'; img-src blob: data:; style-src 'unsafe-inline'; "
    "script-src 'unsafe-inline'; connect-src 'none'; object-src 'none'; "
    "base-uri 'none'; form-action 'none'"
)


def detect_private_lan_ips() -> list[str]:
    """Best-effort offline discovery of local private IPv4 addresses without network traffic."""
    candidates: set[str] = set()
    try:
        host_ips = socket.gethostbyname_ex(socket.gethostname())[2]
        candidates.update(host_ips)
    except OSError:
        pass
    # UDP connect() on a datagram socket sends zero packets on the wire; it only queries
    # the local kernel routing table for the outbound interface address.
    for probe in ("192.168.0.1", "10.0.0.1", "172.16.0.1"):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect((probe, 80))
            ip = sock.getsockname()[0]
            if ip:
                candidates.add(ip)
        except OSError:
            pass
        finally:
            sock.close()
    private_ips: set[str] = set()
    for ip in candidates:
        try:
            parsed = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if parsed.version == 4 and parsed.is_private and not parsed.is_loopback and not parsed.is_link_local:
            private_ips.add(str(parsed))
    return sorted(private_ips)


class StudioOnlyHandler(BaseHTTPRequestHandler):
    def _reject_method(self) -> None:
        self.send_response(HTTPStatus.METHOD_NOT_ALLOWED)
        self.send_header("Allow", "GET, HEAD")
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", STUDIO_CSP)
        self.end_headers()
        self.wfile.write(b"405 Method Not Allowed: read-only single-file studio server.\n")

    def _serve(self, head_only: bool = False) -> None:
        clean_path = urlsplit(self.path).path
        if clean_path not in ("/", "/index.html", "/local_annotation_studio.html"):
            self.send_response(HTTPStatus.NOT_FOUND)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy", STUDIO_CSP)
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
        self.send_header("Content-Security-Policy", STUDIO_CSP)
        self.end_headers()
        if not head_only:
            self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        self._serve(head_only=False)

    def do_HEAD(self) -> None:  # noqa: N802
        self._serve(head_only=True)

    def do_POST(self) -> None:  # noqa: N802
        self._reject_method()

    def do_PUT(self) -> None:  # noqa: N802
        self._reject_method()

    def do_DELETE(self) -> None:  # noqa: N802
        self._reject_method()

    def do_PATCH(self) -> None:  # noqa: N802
        self._reject_method()

    def log_message(self, fmt: str, *args: object) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0", help="bind host (default 0.0.0.0 for LAN/USB)")
    parser.add_argument("--port", type=int, default=8080, help="bind port (default 8080)")
    args = parser.parse_args()

    if not STUDIO_HTML.is_file():
        raise SystemExit(f"Missing studio HTML: {STUDIO_HTML}")

    server = ThreadingHTTPServer((args.host, args.port), StudioOnlyHandler)
    actual_port = server.server_address[1]
    print(
        f"Serving Local Annotation Studio (read-only single-file mode) on {args.host}:{actual_port}",
        flush=True,
    )
    print(f"  - Local / USB (adb reverse tcp:{actual_port} tcp:{actual_port}): http://127.0.0.1:{actual_port}/", flush=True)
    if args.host == "0.0.0.0":
        for lan_ip in detect_private_lan_ips():
            print(f"  - Android on same private Wi-Fi LAN: http://{lan_ip}:{actual_port}/", flush=True)
    print("  - Privacy guard: /Mostmskat/ and /local-data/ are NOT served (HTTP 404); uploads disabled (HTTP 405).", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
