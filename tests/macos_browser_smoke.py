#!/usr/bin/env python3
"""Exercise the packaged GUI, session saving and real layout/paint geometry."""
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import zlib


class GeometryHandler(BaseHTTPRequestHandler):
    fixture = b""

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(self.fixture)))
        self.end_headers()
        self.wfile.write(self.fixture)


def marker_pixels(png, rgb=b"\x12\xab\x34"):
    """Decode stb's non-interlaced RGB/RGBA PNG with no third-party packages."""
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    offset = 8
    compressed = bytearray()
    while offset < len(png):
        length, tag = struct.unpack_from(">I4s", png, offset)
        chunk = png[offset + 8:offset + 8 + length]
        if tag == b"IHDR":
            width, height, bits, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", chunk)
            assert bits == 8 and color in (2, 6)
            assert compression == filtering == interlace == 0
            bpp = 3 if color == 2 else 4
        elif tag == b"IDAT":
            compressed.extend(chunk)
        elif tag == b"IEND":
            break
        offset += length + 12
    raw = zlib.decompress(compressed)
    stride = width * bpp
    assert len(raw) == height * (stride + 1)
    previous = bytearray(stride)
    pixels = []
    for y in range(height):
        start = y * (stride + 1)
        filtering = raw[start]
        assert filtering in range(5)
        row = bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = row[i - bpp] if i >= bpp else 0
            up = previous[i]
            upper_left = previous[i - bpp] if i >= bpp else 0
            if filtering == 0:
                predictor = 0
            elif filtering == 1:
                predictor = left
            elif filtering == 2:
                predictor = up
            elif filtering == 3:
                predictor = (left + up) // 2
            else:
                p = left + up - upper_left
                distances = (abs(p - left), abs(p - up), abs(p - upper_left))
                predictor = (left, up, upper_left)[distances.index(min(distances))]
            row[i] = (row[i] + predictor) & 255
        for x in range(width):
            if row[x * bpp:x * bpp + 3] == rgb:
                pixels.append((x, y))
        previous = row
    return pixels


def smoke(binary, arguments, expected_url, expected_title, geometry=False):
    with tempfile.TemporaryDirectory(prefix="suzume-gui-") as directory:
        profile = Path(directory)
        image = profile / "gui.png"
        result = subprocess.run([
            str(binary), "--gui-smoke", str(image), *arguments,
        ], env=dict(os.environ, HOME=directory, NO_PROXY="127.0.0.1",
                    no_proxy="127.0.0.1"), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=True, timeout=30)
        assert "[gui-smoke]" in result.stderr, result.stderr
        assert "Failed" not in result.stderr, result.stderr
        png = image.read_bytes()
        assert png.startswith(b"\x89PNG\r\n\x1a\n")
        with closing(sqlite3.connect(profile / ".local/share/suzume/suzume.db")) as db:
            data = db.execute("SELECT data FROM sessions ORDER BY id DESC LIMIT 1").fetchone()
        assert data, "browser did not save its session on exit"
        tabs = json.loads(data[0])
        assert tabs[0]["url"] == expected_url, tabs
        assert tabs[0]["title"] == expected_title, tabs
        if geometry:
            pixels = marker_pixels(png)
            assert len(pixels) == 3 * 40 * 20, f"incorrect painted marker area: {len(pixels)}"
            assert min(x for x, _ in pixels) == 40, "root/child left margins were lost in layout/paint"
            assert max(x for x, _ in pixels) == 79, "incorrect marker width"
            assert min(y for _, y in pixels) == 76, "root top margin was lost (64px browser chrome + 12px margin)"
            assert max(y for _, y in pixels) - min(y for _, y in pixels) + 1 == 60
            for rgb, top in [(b"\x11\x22\xaa", 136), (b"\xee\x55\x00", 186),
                             (b"\xff\x00\x88", 246), (b"\x00\xbb\xcc", 306),
                             (b"\xaa\xbb\x00", 326), (b"\xbb\x00\xaa", 346),
                             (b"\xaa\xbb\xcc", 466)]:
                actual = set(marker_pixels(png, rgb))
                expected = {(x, y) for x in range(40, 80) for y in range(top, top + 20)}
                bounds = (min(actual), max(actual)) if actual else None
                assert actual == expected, f"margin/pre layout incorrect for {rgb.hex()}: {len(actual)} pixels, bounds={bounds}"
        print(f"Packaged GUI smoke passed: {expected_url}")


def main():
    root = Path(__file__).resolve().parents[1]
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else
                  root / "zig-out/Suzume.app/Contents/MacOS/suzume").resolve()
    smoke(binary, ["about:blank"], "about:blank", "New Tab")
    # The old startup bug saved 'New Tab' without loading a document.
    smoke(binary, [], "suzume://home", "suzume")
    GeometryHandler.fixture = (root / "tests/fixtures/macos-geometry.html").read_bytes()
    server = ThreadingHTTPServer(("127.0.0.1", 0), GeometryHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{server.server_port}/geometry"
        smoke(binary, [url], url, "Suzume layout smoke", geometry=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
