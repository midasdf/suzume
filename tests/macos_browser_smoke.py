#!/usr/bin/env python3
"""Exercise the packaged browser's real GUI loop with an isolated profile."""
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else
                  root / "zig-out/Suzume.app/Contents/MacOS/suzume").resolve()
    for arguments, expected_url, expected_title in (
        (["about:blank"], "about:blank", "New Tab"),
        ([], "suzume://home", "suzume"),
    ):
        with tempfile.TemporaryDirectory(prefix="suzume-gui-") as directory:
            profile = Path(directory)
            image = profile / "gui.png"
            result = subprocess.run([
                str(binary), "--gui-smoke", str(image), *arguments,
            ], env=dict(os.environ, HOME=directory), text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                check=True, timeout=30)
            assert "[gui-smoke]" in result.stderr, result.stderr
            assert "Failed" not in result.stderr, result.stderr
            assert image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
            with closing(sqlite3.connect(profile / ".local/share/suzume/suzume.db")) as db:
                data = db.execute("SELECT data FROM sessions ORDER BY id DESC LIMIT 1").fetchone()
            assert data, "browser did not save its session on exit"
            tabs = json.loads(data[0])
            assert tabs[0]["url"] == expected_url, tabs
            # The old first-launch bug saved 'New Tab' without loading a document.
            assert tabs[0]["title"] == expected_title, tabs
            print(f"Packaged GUI smoke passed: {expected_url}")


if __name__ == "__main__":
    main()
