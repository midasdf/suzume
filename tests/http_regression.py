#!/usr/bin/env python3
"""Offline HTTP/TLS regression fixture. Usage: python3 tests/http_regression.py [zig flags]."""
import gzip
import http.server
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    revalidations = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        body = b"hello browser"
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/plain")
            self.send_header("ETag", '"redirect-only"')
            self.end_headers()
            return
        if self.path == "/etag" and self.headers.get("If-None-Match") == '"v1"':
            Handler.revalidations += 1
            self.send_response(304)
            self.send_header("ETag", '"v1"')
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        if self.path in ("/etag", "/no-store", "/vary", "/cookie"):
            self.send_header("ETag", '"v1"')
        if self.path == "/no-store":
            self.send_header("Cache-Control", "no-store")
        if self.path == "/vary":
            self.send_header("Vary", "Accept-Language")
        if self.path == "/cookie":
            self.send_header("Set-Cookie", "session=test; Path=/; SameSite=Lax")
        if self.path == "/gzip":
            assert "gzip" in self.headers.get("Accept-Encoding", "")
            body = gzip.compress(body)
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="suzume-http-") as directory:
        cert = Path(directory) / "cert.pem"
        key = Path(directory) / "key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(cert), "-days", "1",
            "-subj", "/CN=localhost",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        plain = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        https = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        https.socket = context.wrap_socket(https.socket, server_side=True)
        servers = (plain, https)
        threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
        for thread in threads:
            thread.start()
        try:
            env = dict(os.environ,
                       SUZUME_TEST_ORIGIN=f"http://127.0.0.1:{plain.server_port}",
                       SUZUME_TEST_TLS_URL=f"https://127.0.0.1:{https.server_port}/plain",
                       NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
            subprocess.run([
                os.environ.get("ZIG", "zig"), "test", "src/net/http.zig", "-lc", "-lcurl",
                *sys.argv[1:],
            ], cwd=root, env=env, check=True)
            assert Handler.revalidations == 1, "304 revalidation did not run"
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()
            for thread in threads:
                thread.join()


if __name__ == "__main__":
    main()
