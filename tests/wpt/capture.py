#!/usr/bin/env python3
"""WPT Visual Regression Test Capture Script.

Usage:
    python3 capture.py                    # Capture all tests, both browsers
    python3 capture.py --suzume-only      # Only capture suzume
    python3 capture.py --firefox-only     # Only capture firefox
    python3 capture.py --test css/001     # Capture specific test (partial match)
"""

import subprocess
import time
import os
import sys
import signal
import glob
import argparse

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(SCRIPT_DIR, "results")
SUZUME_BIN = os.path.join(SCRIPT_DIR, "..", "..", "zig-out", "bin", "suzume")
XEPHYR_DISPLAY = ":99"
WIDTH = 800
HEIGHT = 2000
PORT = 8765


def kill_procs(pattern):
    subprocess.run(["pkill", "-9", "-f", pattern], capture_output=True)
    time.sleep(0.5)


def start_xephyr():
    kill_procs(f"Xephyr.*{XEPHYR_DISPLAY}")
    time.sleep(0.5)
    proc = subprocess.Popen(
        ["Xephyr", XEPHYR_DISPLAY, "-screen", f"{WIDTH}x{HEIGHT}", "-ac"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(2)
    return proc


def stop_xephyr(proc):
    if proc:
        proc.kill()
        proc.wait()
    kill_procs(f"Xephyr.*{XEPHYR_DISPLAY}")


def capture_screenshot(output_path):
    env = os.environ.copy()
    env["DISPLAY"] = XEPHYR_DISPLAY
    subprocess.run(
        ["import", "-window", "root", output_path],
        env=env, capture_output=True, timeout=10
    )


def xdotool(args):
    env = os.environ.copy()
    env["DISPLAY"] = XEPHYR_DISPLAY
    result = subprocess.run(
        ["xdotool"] + args,
        env=env, capture_output=True, text=True, timeout=5
    )
    return result.stdout.strip()


def capture_firefox(url, output_path, wait=12):
    """Capture Firefox screenshot using headless mode (much more reliable)."""
    kill_procs("firefox.*ff-headless-profile")
    time.sleep(1)

    env = os.environ.copy()
    env["MOZ_HEADLESS"] = "1"

    result = subprocess.run(
        ["firefox", "--screenshot", output_path,
         f"--window-size={WIDTH},{HEIGHT}", url],
        env=env, capture_output=True, text=True, timeout=30
    )
    if not os.path.exists(output_path):
        print(f"(FAIL:{result.stderr[:50]})", end=" ")


def capture_suzume(url, output_path, wait=5):
    xephyr = start_xephyr()
    try:
        env = os.environ.copy()
        env["DISPLAY"] = XEPHYR_DISPLAY
        env["SUZUME_WIDTH"] = str(WIDTH)
        env["SUZUME_HEIGHT"] = str(HEIGHT)

        sz = subprocess.Popen(
            [SUZUME_BIN, url],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        time.sleep(wait)
        capture_screenshot(output_path)
        sz.kill()
        sz.wait()
    finally:
        stop_xephyr(xephyr)


def compare_images(ff_path, sz_path, diff_path):
    if not os.path.exists(ff_path) or not os.path.exists(sz_path):
        return "N/A"
    result = subprocess.run(
        ["compare", "-metric", "RMSE", ff_path, sz_path, diff_path],
        capture_output=True, text=True, timeout=30
    )
    return result.stderr.strip()


def collect_tests(filter_str=None):
    tests = []
    for pattern in ["css/*.html", "js/*.html"]:
        for f in sorted(glob.glob(os.path.join(SCRIPT_DIR, pattern))):
            rel = os.path.relpath(f, SCRIPT_DIR)
            name = os.path.basename(f).replace(".html", "")
            category = os.path.basename(os.path.dirname(f))
            full_name = f"{category}_{name}"
            if filter_str and filter_str not in rel and filter_str not in full_name:
                continue
            tests.append((rel, full_name, category))
    return tests


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--suzume-only", action="store_true")
    parser.add_argument("--firefox-only", action="store_true")
    parser.add_argument("--test", type=str, default=None)
    args = parser.parse_args()

    os.makedirs(os.path.join(RESULTS_DIR, "firefox"), exist_ok=True)
    os.makedirs(os.path.join(RESULTS_DIR, "suzume"), exist_ok=True)
    os.makedirs(os.path.join(RESULTS_DIR, "diff"), exist_ok=True)

    # Ensure HTTP server
    subprocess.run(["pkill", "-f", f"python3.*http.server.*{PORT}"], capture_output=True)
    time.sleep(0.5)
    http_proc = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(PORT)],
        cwd=SCRIPT_DIR, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(1)

    tests = collect_tests(args.test)
    print(f"=== WPT Visual Regression: {len(tests)} tests ===\n")

    try:
        for rel, full_name, category in tests:
            url = f"http://localhost:{PORT}/{rel}"
            ff_img = os.path.join(RESULTS_DIR, "firefox", f"{full_name}.png")
            sz_img = os.path.join(RESULTS_DIR, "suzume", f"{full_name}.png")
            diff_img = os.path.join(RESULTS_DIR, "diff", f"{full_name}.png")

            wait = 8 if category == "js" else 6
            print(f"[{full_name}]", end=" ", flush=True)

            if not args.suzume_only:
                print("FF..", end="", flush=True)
                capture_firefox(url, ff_img, wait=max(wait, 12))
                sz = os.path.getsize(ff_img) if os.path.exists(ff_img) else 0
                print(f"({sz//1024}K)", end=" ", flush=True)

            if not args.firefox_only:
                print("SZ..", end="", flush=True)
                capture_suzume(url, sz_img, wait=wait)
                sz = os.path.getsize(sz_img) if os.path.exists(sz_img) else 0
                print(f"({sz//1024}K)", end=" ", flush=True)

            if os.path.exists(ff_img) and os.path.exists(sz_img):
                rmse = compare_images(ff_img, sz_img, diff_img)
                print(f"RMSE={rmse}")
            else:
                print("(skip compare)")

    finally:
        http_proc.kill()
        http_proc.wait()
        kill_procs(f"Xephyr.*{XEPHYR_DISPLAY}")

    print(f"\n=== Done. Results in {RESULTS_DIR}/ ===")


if __name__ == "__main__":
    main()
